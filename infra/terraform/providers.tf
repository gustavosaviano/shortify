# No endpoints or credentials here on purpose: the provider reads AWS_ENDPOINT_URL,
# AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY and AWS_DEFAULT_REGION from the environment.
# The same code targets Floci or real AWS depending only on that environment.

# One source of truth: the provider applies these to every resource, and emulator
# checks compare against them (never against a resource's own read-back tags).
locals {
  default_tags = {
    Project   = "shortify"
    ManagedBy = "terraform"
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = local.default_tags
  }
}
