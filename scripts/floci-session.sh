#!/usr/bin/env bash
# Floci only: one command from a cold boot to a healthy target behind the ALB.
#   1. start the Floci stack
#   2. network check: reconnect Floci to the VPC network if a recreate dropped it (#11)
#   3. instance check; if the instance isn't usable, replace it (asks before applying, #26)
#   4. deploy with Ansible: output to a log file, judged by its real exit code (#56)
#   5. cutover with scripts/release-register.sh, the same step as on AWS
# Each step runs only if the previous one succeeded; a failure names the step and exits 1.
# Run it through shortify_session (~/.bashrc), which re-sources the IDs afterwards:
# a script can't change its caller's shell variables.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
floci_ui_dir="${FLOCI_UI_DIR:-$HOME/workspace/floci-ui}"
playbook="${ANSIBLE_PLAYBOOK_BIN:-$HOME/.venvs/shortify-ansible/bin/ansible-playbook}"
fail() { echo "session: FAILED at step $1" >&2; exit 1; }

echo "== session 1/5: start the Floci stack"
(cd "$floci_ui_dir" && docker compose start) || fail "1/5 (docker compose start)"

echo "== session 2/5: network"
# shellcheck source=scripts/shortify-env.sh
source scripts/shortify-env.sh || fail "2/5 (read the IDs from Terraform)"
bash scripts/floci-network-check.sh || fail "2/5 (network check)"

echo "== session 3/5: instance"
if ! bash scripts/floci-instance-check.sh; then
  bash scripts/floci-replace-instance.sh || fail "3/5 (replace the instance)"
  # shellcheck source=scripts/shortify-env.sh
  source scripts/shortify-env.sh || fail "3/5 (re-read the IDs after the replace)"
fi

echo "== session 4/5: deploy"
log=$(mktemp /tmp/shortify-deploy.XXXXXX.log)
"$playbook" infra/ansible/app.yml > "$log" 2>&1
rc=$?
grep -E '^\S+ +: ok=' "$log"
if [ "$rc" -ne 0 ]; then
  grep -A10 'fatal:' "$log" >&2
  fail "4/5 (deploy exited $rc; full log: $log)"
fi

echo "== session 5/5: cutover"
bash scripts/release-register.sh || fail "5/5 (cutover)"
echo "session: ready: $INSTANCE_ID behind the ALB (log of the deploy: $log)"
