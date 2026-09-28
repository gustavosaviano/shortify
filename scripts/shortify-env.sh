# Session helper: exports the IDs the runbook uses, read from Terraform outputs.
# Source it, don't run it:  source scripts/shortify-env.sh
# Fails loudly and exports nothing if the state or any output is missing:
# an empty or "None" ID must never reach an AWS command (edge cases #7, #22).
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "shortify-env: source this file, don't execute it" >&2; exit 1
fi

_shortify_tf="$(cd "$(dirname "${BASH_SOURCE[0]}")/../infra/terraform" && pwd)"
if ! _shortify_json=$(terraform -chdir="$_shortify_tf" output -json 2>/dev/null) || [ "$_shortify_json" = "{}" ]; then
  echo "shortify-env: no Terraform outputs in $_shortify_tf (state missing or empty)" >&2
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
unset _shortify_tf _shortify_json _shortify_exports
