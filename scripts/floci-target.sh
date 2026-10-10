# shellcheck shell=bash  # sourced, never executed, so it has no shebang
# The Floci target: the endpoint, region and dummy credentials that the AWS CLI, the
# Terraform provider and the S3 backend read from the environment (edge cases #67, #68).
# The repo defines the target, not ~/.bashrc or whoever started the runner (#65). The values
# are the ones `floci env` (CLI 0.2.3) prints. Real AWS never uses this file.
# It reads nothing, so a fresh checkout can use it before Terraform is initialized, which
# scripts/shortify-env.sh can't (edge case #72):
#   source scripts/floci-target.sh && terraform -chdir=infra/terraform init -backend-config=backend-floci.hcl
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "floci-target: source this file, don't execute it" >&2; exit 1
fi
export AWS_ENDPOINT_URL=http://localhost.floci.io:4566
export AWS_DEFAULT_REGION=us-east-1
export AWS_ACCESS_KEY_ID=test
export AWS_SECRET_ACCESS_KEY=test
