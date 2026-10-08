# State lives in S3 so every operator (the laptop, the deploy runner) reads the same
# state through the API, with one lock (use_lockfile: S3 conditional writes; the
# DynamoDB lock is deprecated). The bucket comes from infra/bootstrap.
#
# No endpoint, path-style or skip_* settings: the backend reads AWS_ENDPOINT_URL and
# the credentials from the environment, like the provider. Tested against Floci 2.1.0
# with nothing else set (edge case #67).
#
# The bucket name contains the account ID, which differs per environment, and a
# backend block can't use variables. So it comes from a per-environment file:
#   terraform init -backend-config=backend-floci.hcl
terraform {
  backend "s3" {
    key          = "shortify/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true
    encrypt      = true
  }
}
