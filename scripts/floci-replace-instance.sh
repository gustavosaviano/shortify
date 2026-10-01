#!/usr/bin/env bash
# Floci only: replace the app instance after a Floci stop or PC restart (runbook section 3).
# An instance never survives a Floci stop (edge cases #9, #26) and nothing else reports it
# (#48), so this is the routine fix: replace, don't repair. It refuses any plan that does more
# than replace the instance and asks before applying. Run it through shortify_replace (~/.bashrc),
# which re-sources the IDs afterwards: a script can't change its caller's shell variables.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
tf() { terraform -chdir=infra/terraform "$@"; }
plan_out=$(mktemp)
trap 'rm -f infra/terraform/tfplan "$plan_out"' EXIT

if ! tf plan -replace=aws_instance.app -no-color -out tfplan > "$plan_out" 2>&1; then
  cat "$plan_out" >&2; exit 1
fi
grep -E '^\s+# ' "$plan_out" || true
summary=$(grep -E '^Plan:' "$plan_out" || true)
echo "$summary"
if [ "$summary" != "Plan: 1 to add, 0 to change, 1 to destroy." ]; then
  echo "refusing: this plan does more than replace the instance; review it with terraform plan" >&2
  exit 1
fi
read -r -p "Replace the instance? Type yes to apply: " answer
[ "$answer" = yes ] || { echo "not applied"; exit 1; }
tf apply -no-color tfplan | grep -E 'complete|Error'

instance_id=$(tf output -raw instance_id)
port=$(docker port "floci-ec2-$instance_id" 22/tcp | head -1 | sed 's/.*://')
ssh-keygen -R "[127.0.0.1]:$port" > /dev/null 2>&1 || true   # new instance, new host key
for _ in $(seq 1 18); do INSTANCE_ID=$instance_id bash scripts/floci-instance-check.sh > /dev/null 2>&1 && break; sleep 5; done
INSTANCE_ID=$instance_id bash scripts/floci-instance-check.sh

# A login only proves some key matches: require exactly the one from ~/.ssh/shortify-real.pub (#48).
remote=$(ssh -i ~/.ssh/shortify-real -p "$port" -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
  root@127.0.0.1 'ssh-keygen -lf /root/.ssh/authorized_keys')
if [ "$remote" != "$(ssh-keygen -lf ~/.ssh/shortify-real.pub)" ]; then
  echo "key check failed: authorized_keys on the instance is:" >&2; echo "$remote" >&2; exit 1
fi
echo "key ok: exactly one entry, matching ~/.ssh/shortify-real.pub"
