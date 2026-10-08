#!/usr/bin/env bash
# Tests for scripts/: each case runs a real script against fake CLIs (tests/scripts/fakes)
# and checks its exit code, its output and the calls it made. No AWS, Docker, SSH or
# Ansible needed, so the same tests run on a laptop and in CI (job "Scripts").
# They prove the scripts' logic, not the emulator: behavior on Floci is tested live and
# recorded in docs/edge-cases.md.
# Usage, from anywhere:  bash tests/scripts/run.sh
# shellcheck disable=SC2016  # stub code and bash -c snippets are written unexpanded on purpose
set -uo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd) || exit 1
fakes="$root/tests/scripts/fakes"
work=$(mktemp -d) || exit 1
trap 'rm -rf "$work"' EXIT
failures=0
cases=0
# Variables a laptop shell may have exported (shortify-env.sh, ~/.bashrc): cleared for every
# case, so a test can't pass or fail because of the shell it runs in.
clean=()
for v in VPC_ID PUB1 PUB2 ALB_SG EC2_SG RDS_SG TG_ARN ALB_DNS DB_PORT DB_SECRET LT_ID LT_VERSION \
  INSTANCE_ID ANSIBLE_CONFIG ANSIBLE_PLAYBOOK_BIN FLOCI_UI_DIR SHORTIFY_RELEASE_IMAGE \
  AWS_ENDPOINT_URL AWS_DEFAULT_REGION AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY; do clean+=(-u "$v"); done

# run <name> <expected exit> <dir> <env assignments and command...>
# Runs the command in <dir> with the fakes first on PATH; keeps its output and the calls.
run() {
  local name=$1 want=$2 dir=$3
  shift 3
  cases=$((cases + 1))
  current=$name
  case_failed=0
  : > "$work/calls"
  rm -f "$work/registered"
  (cd "$dir" && env "${clean[@]}" PATH="$fakes:$PATH" FAKE_LOG="$work/calls" FAKE_STATE="$work" "$@") > "$work/out" 2>&1
  local got=$?
  if [ "$got" -ne "$want" ]; then
    report "exit $got, want $want"
    return 1
  fi
}
report() {
  echo "FAIL  $current: $1"
  if [ "$case_failed" -eq 0 ]; then
    sed 's/^/      | /' "$work/out"
    failures=$((failures + 1))
    case_failed=1
  fi
}
# expect out|calls <text> / refuse out|calls <text>: the output or the call log must (not) contain it.
expect() { grep -qF -- "$2" "$work/$1" || report "$1 lacks: $2"; }
refuse() { if grep -qF -- "$2" "$work/$1"; then report "$1 has: $2"; fi; }
ok() { echo "ok    $current"; }

commit=$(git -C "$root" rev-parse HEAD) || exit 1
release_env=(TG_ARN=arn:tg LT_ID=lt-1 LT_VERSION=1 PUB1=subnet-a ALB_DNS=alb.local
  ANSIBLE_CONFIG=/dev/null ANSIBLE_PLAYBOOK_BIN="$fakes/ansible-playbook" FAKE_COMMIT="$commit")

# ── scripts/release.sh ──────────────────────────────────────────────────────────
before=$failures
run "release: happy path" 0 "$root" "${release_env[@]}" bash scripts/release.sh ami-test-1 && {
  expect calls "ec2 run-instances --launch-template LaunchTemplateId=lt-1,Version=1 --image-id ami-test-1 --subnet-id subnet-a"
  expect calls "Tags=[{Key=Release,Value=$commit}]"
  expect calls "ansible-playbook INSTANCE_ID=i-new"
  expect calls "elbv2 register-targets --target-group-arn arn:tg --targets Id=i-new,Port=8000"
  expect calls "elbv2 deregister-targets --target-group-arn arn:tg --targets Id=i-old,Port=8000"
  expect calls "ec2 terminate-instances --instance-ids i-oldrel i-failed"
  expect out "left alone: i-tf (running, ManagedBy=terraform)"
  refuse out "i-dead"
  refuse out "i-other"
}
[ "$failures" -eq "$before" ] && ok

before=$failures
run "release: IMDSv2 not required on the instance stops before any traffic" 1 "$root" "${release_env[@]}" FAKE_TOKENS=optional bash scripts/release.sh ami-test-1 && {
  expect out "FAILED at step 1/5"
  refuse calls "ansible-playbook"
  refuse calls "register-targets"
  refuse calls "terminate-instances"
}
[ "$failures" -eq "$before" ] && ok

before=$failures
run "release: invalid image launches nothing" 2 "$root" "${release_env[@]}" bash scripts/release.sh ami_bad && {
  refuse calls "aws "
}
[ "$failures" -eq "$before" ] && ok

before=$failures
run "release: failed deploy never reaches the target group" 1 "$root" "${release_env[@]}" FAKE_DEPLOY_RC=2 bash scripts/release.sh ami-test-1 && {
  expect out "FAILED at step 3/5"
  refuse calls "register-targets"
  refuse calls "terminate-instances"
}
[ "$failures" -eq "$before" ] && ok

before=$failures
run "release: a new target that never gets healthy leaves the old one serving" 1 "$root" "${release_env[@]}" FAKE_NEVER_HEALTHY=1 bash scripts/release.sh ami-test-1 && {
  expect out "FAILED at step 4/5"
  expect calls "elbv2 deregister-targets --target-group-arn arn:tg --targets Id=i-new,Port=8000"
  refuse calls "Id=i-old,Port=8000"
  refuse calls "terminate-instances"
}
[ "$failures" -eq "$before" ] && ok

before=$failures
run "release: refuses without the env" 1 "$root" bash scripts/release.sh ami-test-1 && {
  expect out "source scripts/shortify-env.sh first"
  refuse calls "aws "
}
[ "$failures" -eq "$before" ] && ok

# ── scripts/shortify-env.sh: INSTANCE_ID is the target group's one instance ────
show='source scripts/shortify-env.sh; echo "INSTANCE_ID=${INSTANCE_ID:-<unset>} LT=$LT_ID/$LT_VERSION"'
env_case() {  # env_case <name> <FAKE_TG_IDS> <expected INSTANCE_ID> [extra env...]
  local name=$1 ids=$2 want=$3
  shift 3
  before=$failures
  run "env: $name" 0 "$root" INSTANCE_ID=stale FAKE_TG_IDS="$ids" "$@" bash -c "$show" && {
    expect out "INSTANCE_ID=$want LT=lt-1/1"
  }
  [ "$failures" -eq "$before" ] && ok
}
env_case "one target" 'i-1\n' i-1
env_case "two targets: none exported" 'i-1\ti-2\n' '<unset>'
env_case "no target" '' '<unset>'
env_case "same instance registered twice" 'i-1\ti-1\n' i-1
env_case "target group unreadable" 'i-1\n' '<unset>' FAKE_TG_FAIL=1

before=$failures
run "env: ANSIBLE_CONFIG points at the repo's ansible.cfg (edge case #50)" 0 "$root" FAKE_TG_IDS='i-1\n' bash -c 'source scripts/shortify-env.sh; echo "ANSIBLE_CONFIG=$ANSIBLE_CONFIG"' && {
  expect out "ANSIBLE_CONFIG=$root/infra/ansible/ansible.cfg"
}
[ "$failures" -eq "$before" ] && ok

before=$failures
run "env: sets the Floci target before reading Terraform (edge case #68)" 0 "$root" AWS_ENDPOINT_URL=http://elsewhere:1 FAKE_TG_IDS='i-1\n' bash -c 'source scripts/shortify-env.sh; echo "endpoint=$AWS_ENDPOINT_URL region=$AWS_DEFAULT_REGION"' && {
  expect out "endpoint=http://localhost.floci.io:4566 region=us-east-1"
  expect calls "output -json (endpoint=http://localhost.floci.io:4566)"
  refuse calls "elsewhere"
}
[ "$failures" -eq "$before" ] && ok

before=$failures
run "env: uninitialized backend fails with the init command" 1 "$root" FAKE_TF_FAIL=1 bash -c 'source scripts/shortify-env.sh' && {
  expect out "init -backend-config=backend-floci.hcl"
  refuse calls "aws "
}
[ "$failures" -eq "$before" ] && ok

# ── scripts/floci-session.sh: branches, with its sub-scripts stubbed ───────────
s="$work/session"
mkdir -p "$s/scripts" "$s/infra/ansible"
cp "$root/scripts/floci-session.sh" "$s/scripts/"
printf '%s\n' 'unset INSTANCE_ID; if [ -n "${FAKE_ID:-}" ]; then export INSTANCE_ID=$FAKE_ID; fi' > "$s/scripts/shortify-env.sh"
printf '%s\n' 'exit 0' > "$s/scripts/floci-network-check.sh"
printf '%s\n' 'echo "instance check called"; [ "${FAKE_USABLE:-}" = yes ]' > "$s/scripts/floci-instance-check.sh"
printf '%s\n' 'echo "release.sh called with $*"; exit "${FAKE_RELEASE_RC:-0}"' > "$s/scripts/release.sh"
printf '%s\n' 'echo "release-register.sh called for $INSTANCE_ID"' > "$s/scripts/release-register.sh"
session_env=(FLOCI_UI_DIR="$work" ANSIBLE_PLAYBOOK_BIN="$fakes/ansible-playbook")

before=$failures
run "session: usable instance gets a deploy and a cutover check" 0 "$s" "${session_env[@]}" FAKE_ID=i-a FAKE_USABLE=yes bash scripts/floci-session.sh && {
  expect calls "ansible-playbook"
  expect out "release-register.sh called for i-a"
  refuse out "release.sh called"
}
[ "$failures" -eq "$before" ] && ok

before=$failures
run "session: dead instance gets a release" 0 "$s" "${session_env[@]}" FAKE_ID=i-a FAKE_USABLE=no bash scripts/floci-session.sh && {
  expect out "release.sh called with ami-ubuntu2404-amd64"
  refuse calls "ansible-playbook"
}
[ "$failures" -eq "$before" ] && ok

before=$failures
run "session: no registered instance gets a release without a check" 0 "$s" "${session_env[@]}" FAKE_USABLE=yes bash scripts/floci-session.sh && {
  expect out "release.sh called with ami-ubuntu2404-amd64"
  refuse out "instance check called"
}
[ "$failures" -eq "$before" ] && ok

before=$failures
run "session: failed release fails the session" 1 "$s" "${session_env[@]}" FAKE_ID=i-a FAKE_USABLE=no FAKE_RELEASE_RC=1 bash scripts/floci-session.sh && {
  expect out "FAILED at step 4/4 (release)"
}
[ "$failures" -eq "$before" ] && ok

before=$failures
run "session: failed deploy fails the session before the cutover" 1 "$s" "${session_env[@]}" FAKE_ID=i-a FAKE_USABLE=yes FAKE_DEPLOY_RC=2 bash scripts/floci-session.sh && {
  expect out "FAILED at step 4/4 (deploy exited 2"
  refuse out "release-register.sh called"
}
[ "$failures" -eq "$before" ] && ok

echo "$((cases - failures)) of $cases cases passed"
[ "$failures" -eq 0 ]
