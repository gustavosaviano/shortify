# shellcheck shell=bash  # sourced, never executed, so it has no shebang
# Session helper: exports the IDs the runbook uses, read from Terraform outputs.
# Source it, don't run it:  source scripts/shortify-env.sh
# It sets the Floci target first (scripts/floci-target.sh). After that it's all-or-nothing:
# if the state or any output is missing, it fails loudly and exports no ID, because an
# empty or "None" ID must never reach an AWS command (edge cases #7, #22).
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "shortify-env: source this file, don't execute it" >&2; exit 1
fi

# shellcheck source=scripts/floci-target.sh
source "$(dirname "${BASH_SOURCE[0]}")/floci-target.sh" || return 1

_shortify_tf="$(cd "$(dirname "${BASH_SOURCE[0]}")/../infra/terraform" && pwd)"
# State is remote (S3): a fresh checkout must init the backend first (runbook section 9).
if ! _shortify_json=$(terraform -chdir="$_shortify_tf" output -json 2>/dev/null) || [ "$_shortify_json" = "{}" ]; then
  echo "shortify-env: no Terraform outputs in $_shortify_tf: backend not initialized" >&2
  echo "  (source scripts/floci-target.sh; terraform -chdir=infra/terraform init -backend-config=backend-floci.hcl)," >&2
  echo "  or the state is empty" >&2
  unset _shortify_tf _shortify_json; return 1
fi

if ! _shortify_exports=$(python3 - "$_shortify_json" << 'PY'
import json, shlex, sys
out = {k: v["value"] for k, v in json.loads(sys.argv[1]).items()}
wanted = {
    "VPC_ID":    lambda o: o["vpc_id"],
    "PUB1":      lambda o: o["public_subnet_ids"][0],
    "PUB2":      lambda o: o["public_subnet_ids"][1],
    "ALB_SG":    lambda o: o["security_group_ids"]["alb"],
    "EC2_SG":    lambda o: o["security_group_ids"]["app"],
    "RDS_SG":    lambda o: o["security_group_ids"]["db"],
    "TG_ARN":    lambda o: o["target_group_arn"],
    "ALB_DNS":   lambda o: o["alb_dns_name"],
    "DB_PORT":   lambda o: o["db_endpoint"]["port"],   # connect to localhost (edge case #14)
    "DB_SECRET": lambda o: o["db_master_secret_arn"],
    "LT_ID":     lambda o: o["launch_template"]["id"],       # release instances launch from it
    "LT_VERSION": lambda o: o["launch_template"]["version"], # pinned, never $Latest
}
lines = []
for name, get in wanted.items():
    try:
        value = str(get(out))
    except (KeyError, IndexError, TypeError):
        sys.exit(f"shortify-env: output for {name} is missing")
    if not value or value == "None":
        sys.exit(f"shortify-env: output for {name} is empty")
    lines.append(f"export {name}={shlex.quote(value)}")
print("\n".join(lines))
PY
); then
  unset _shortify_tf _shortify_json _shortify_exports; return 1
fi

eval "$_shortify_exports"

# The app instance is whatever the target group serves: membership is the release state
# (knowledge base, "who registers targets"), and since Phase 3b a release, not Terraform,
# launches it. Exported only when exactly one instance is registered: mid-release or after
# a failed cutover there can be two, and a guess must never reach a command (#22).
# A stale value from an earlier source is cleared first.
unset INSTANCE_ID
if _shortify_ids=$(aws elbv2 describe-target-health --target-group-arn "$TG_ARN" \
    --query 'TargetHealthDescriptions[].Target.Id' --output text 2>/dev/null); then
  _shortify_ids=$(tr '\t' '\n' <<< "$_shortify_ids" | grep -vxE 'None|' | sort -u)
  _shortify_n=$(grep -c . <<< "$_shortify_ids")
  if [ "$_shortify_n" -eq 1 ]; then
    export INSTANCE_ID="$_shortify_ids"
  else
    echo "shortify-env: INSTANCE_ID not set: $_shortify_n instances registered in the target group, expected 1" >&2
  fi
else
  echo "shortify-env: INSTANCE_ID not set: can't read the target group" >&2
fi
unset _shortify_ids _shortify_n

# Ansible ignores an ansible.cfg in a world-writable current directory, and on this laptop's
# Windows drive every directory looks world-writable (edge cases #39, #50): point to it explicitly.
if ! _shortify_ansible=$(cd "$(dirname "${BASH_SOURCE[0]}")/../infra/ansible" && pwd); then
  echo "shortify-env: infra/ansible not found next to this script" >&2
  unset _shortify_tf _shortify_json _shortify_exports _shortify_ansible; return 1
fi
export ANSIBLE_CONFIG="$_shortify_ansible/ansible.cfg"
unset _shortify_tf _shortify_json _shortify_exports _shortify_ansible
