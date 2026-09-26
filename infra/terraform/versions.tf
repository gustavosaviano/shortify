terraform {
  # Pinned like Python and the CI actions: changes only when we decide.
  required_version = "~> 1.16.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0" # exact build recorded in .terraform.lock.hcl (committed)
    }
  }
}
