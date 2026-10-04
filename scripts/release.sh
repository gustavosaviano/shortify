#!/usr/bin/env bash
# Release: one new instance per release, never an in-place update (immutable deploys,
# README key decisions). Each step runs only if the previous one succeeded:
#   1. launch from the launch template at the version Terraform pinned, with the release
#      image (the argument) and a Release=<commit> tag; verify IMDSv2 and the tags on the
#      instance itself, not the request (edge cases #57, #60)
#   2. wait until it's usable and trusts exactly our key (edge cases #9, #25, #48)
#   3. deploy the commit with Ansible: output to a log file, judged by its exit code (#56)
#   4. cut over with scripts/release-register.sh: the old instance serves until the new
#      one is healthy, so a campaign link never sees a gap
#   5. terminate every other instance a release launched (ManagedBy=release), leftovers of
#      failed releases included. Instances with any other ManagedBy are only reported.
# A failure before or during the cutover leaves the old instance serving and the new one
# running for inspection; the next successful release terminates it. One release at a time.
# Floci only for now: steps 2-3 use Floci's SSH host ports (inventories/floci). On AWS,
# step 2 becomes `aws ec2 wait instance-status-ok` and the inventory changes (not tested).
# Usage, after sourcing scripts/shortify-env.sh:  bash scripts/release.sh <image-id>
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
need="source scripts/shortify-env.sh first"
: "${TG_ARN:?$need}" "${LT_ID:?$need}" "${LT_VERSION:?$need}" "${PUB1:?$need}" "${ALB_DNS:?$need}" "${ANSIBLE_CONFIG:?$need}"
playbook="${ANSIBLE_PLAYBOOK_BIN:-$HOME/.venvs/shortify-ansible/bin/ansible-playbook}"
fail() { echo "release: FAILED at step $1" >&2; exit 1; }

image="${1:-}"
if [[ ! "$image" =~ ^ami-[a-z0-9-]+$ ]]; then
  echo "usage: bash scripts/release.sh <image-id>   (got '$image')" >&2; exit 2
fi
commit=$(git rev-parse HEAD) || fail "0/5 (read the commit)"
# The playbook refuses uncommitted app changes too, but only after an instance exists.
if [ -n "$(git status --porcelain -- app requirements.txt)" ]; then
  echo "release: uncommitted changes in app/ or requirements.txt; commit them first" >&2; exit 1
fi

echo "== release 1/5: launch $image from $LT_ID version $LT_VERSION (commit ${commit:0:7})"
new=$(aws ec2 run-instances --launch-template "LaunchTemplateId=$LT_ID,Version=$LT_VERSION" \
  --image-id "$image" --subnet-id "$PUB1" \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Release,Value=$commit}]" \
  --query 'Instances[0].InstanceId' --output text) || fail "1/5 (run-instances)"
case "$new" in i-*) ;; *) fail "1/5 (run-instances returned '$new')" ;; esac
echo "release: launched $new"
aws ec2 wait instance-running --instance-ids "$new" || fail "1/5 (waiting for $new to run)"
# shellcheck disable=SC2016  # JMESPath literals use backticks; nothing to expand
got=$(aws ec2 describe-instances --instance-ids "$new" --query \
  'Reservations[0].Instances[0].[MetadataOptions.HttpTokens, Tags[?Key==`ManagedBy`].Value | [0], Tags[?Key==`Release`].Value | [0]]' \
  --output text) || fail "1/5 (describe $new)"
want=$(printf '%s\t%s\t%s' required release "$commit")
if [ "$got" != "$want" ]; then
  echo "release: $new doesn't carry the template's settings: got [$got], want [$want]" >&2
  fail "1/5 (verify $new; left running for inspection)"
fi

echo "== release 2/5: wait until $new is usable"
for _ in $(seq 1 18); do INSTANCE_ID=$new bash scripts/floci-instance-check.sh > /dev/null 2>&1 && break; sleep 5; done
INSTANCE_ID=$new bash scripts/floci-instance-check.sh || fail "2/5 ($new not usable after 90 s; left running for inspection)"
port=$(docker port "floci-ec2-$new" 22/tcp | head -1 | sed 's/.*://') || fail "2/5 (read the SSH port of $new)"
case "$port" in ''|*[!0-9]*) fail "2/5 (SSH port of $new is '$port')" ;; esac
ssh-keygen -R "[127.0.0.1]:$port" > /dev/null 2>&1 || true   # host ports are reused across instances (#60)
# A login only proves some key matches: require exactly the one from ~/.ssh/shortify-real.pub (#48).
remote=$(ssh -i ~/.ssh/shortify-real -p "$port" -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
  root@127.0.0.1 'ssh-keygen -lf /root/.ssh/authorized_keys') || fail "2/5 (SSH to $new)"
if [ "$remote" != "$(ssh-keygen -lf ~/.ssh/shortify-real.pub)" ]; then
  echo "release: authorized_keys on $new is:" >&2; echo "$remote" >&2
  fail "2/5 (key check on $new)"
fi
echo "release: key ok: exactly one entry, matching ~/.ssh/shortify-real.pub"

echo "== release 3/5: deploy ${commit:0:7} to $new"
log=$(mktemp /tmp/shortify-release.XXXXXX.log)
INSTANCE_ID=$new "$playbook" infra/ansible/app.yml > "$log" 2>&1
rc=$?
grep -E '^\S+ +: ok=' "$log"
if [ "$rc" -ne 0 ]; then
  grep -A10 'fatal:' "$log" >&2
  fail "3/5 (deploy exited $rc; log: $log; $new left running for inspection)"
fi

echo "== release 4/5: cutover"
INSTANCE_ID=$new bash scripts/release-register.sh || fail "4/5 (cutover; the previous targets keep serving)"

echo "== release 5/5: retire what this release replaced"
# Filtered client-side: the query only shapes the output, so it can't depend on which
# server-side filters the emulator implements.
# shellcheck disable=SC2016  # JMESPath literals use backticks; nothing to expand
all=$(aws ec2 describe-instances --query \
  'Reservations[].Instances[].[InstanceId, State.Name, Tags[?Key==`Project`].Value | [0], Tags[?Key==`ManagedBy`].Value | [0]]' \
  --output text) || fail "5/5 (list instances)"
retire=()
while read -r id state project managed; do
  [ -z "$id" ] || [ "$id" = "$new" ] || [ "$project" != shortify ] && continue
  case "$state" in terminated|shutting-down) continue ;; esac
  if [ "$managed" = release ]; then
    retire+=("$id")
  else
    echo "release: left alone: $id ($state, ManagedBy=$managed)"
  fi
done <<< "$all"
if [ "${#retire[@]}" -gt 0 ]; then
  echo "release: terminating ${retire[*]}"
  aws ec2 terminate-instances --instance-ids "${retire[@]}" > /dev/null || fail "5/5 (terminate ${retire[*]})"
  aws ec2 wait instance-terminated --instance-ids "${retire[@]}" || fail "5/5 (waiting for ${retire[*]} to terminate)"
else
  echo "release: no earlier release instances to retire"
fi
echo "release: $new serves ${commit:0:7} behind the ALB (deploy log: $log)"
