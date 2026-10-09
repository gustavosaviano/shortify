#!/usr/bin/env bash
# Floci only: one command from a cold boot to a healthy target behind the ALB.
#   1. start the Floci stack
#   2. network check: reconnect Floci to the VPC network if a recreate dropped it (#11)
#   3. instance check: the instance the target group serves (scripts/shortify-env.sh)
#   4. if it's usable: deploy to it with Ansible (output to a log file, judged by its real
#      exit code, #56) and confirm the cutover with scripts/release-register.sh.
#      If it isn't, or none is registered: a release replaces it (scripts/release.sh), the
#      same process as shipping a version: replace, don't repair (#9, #26). No prompt: a
#      release only launches one instance from the pinned template and verifies it.
# Each step runs only if the previous one succeeded; a failure names the step and exits 1.
# The whole session holds the host's release lock (scripts/release-lock.sh): its in-place
# deploy must not overlap a release from the pipeline, and its cold path runs release.sh
# under the same lock instead of taking it again.
# Run it through shortify_session (~/.bashrc), which re-sources the IDs afterwards:
# a script can't change its caller's shell variables.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
# shellcheck source=scripts/release-lock.sh
source scripts/release-lock.sh || exit 1
release_lock session "$PWD/scripts/floci-session.sh"
floci_ui_dir="${FLOCI_UI_DIR:-$HOME/workspace/floci-ui}"
playbook="${ANSIBLE_PLAYBOOK_BIN:-$HOME/.venvs/shortify-ansible/bin/ansible-playbook}"
# Floci's only amd64 image (#9). On AWS the pipeline passes the image it built (Phase 3b).
image="${SHORTIFY_RELEASE_IMAGE:-ami-ubuntu2404-amd64}"
fail() { echo "session: FAILED at step $1" >&2; exit 1; }

echo "== session 1/4: start the Floci stack"
(cd "$floci_ui_dir" && docker compose start) || fail "1/4 (docker compose start)"

echo "== session 2/4: network"
# shellcheck source=scripts/shortify-env.sh
source scripts/shortify-env.sh || fail "2/4 (read the IDs from Terraform)"
bash scripts/floci-network-check.sh || fail "2/4 (network check)"

echo "== session 3/4: instance"
if [ -n "${INSTANCE_ID:-}" ] && bash scripts/floci-instance-check.sh; then
  echo "== session 4/4: deploy to $INSTANCE_ID and confirm the cutover"
  log=$(mktemp /tmp/shortify-deploy.XXXXXX.log)
  "$playbook" infra/ansible/app.yml > "$log" 2>&1
  rc=$?
  grep -E '^\S+ +: ok=' "$log"
  if [ "$rc" -ne 0 ]; then
    grep -A10 'fatal:' "$log" >&2
    fail "4/4 (deploy exited $rc; full log: $log)"
  fi
  bash scripts/release-register.sh || fail "4/4 (cutover)"
  echo "session: ready: $INSTANCE_ID behind the ALB (log of the deploy: $log)"
else
  echo "== session 4/4: no usable instance behind the ALB; a release replaces it"
  bash scripts/release.sh "$image" || fail "4/4 (release)"
  echo "session: ready"
fi
