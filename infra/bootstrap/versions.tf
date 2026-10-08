terraform {
  # Same pins as infra/terraform: both roots change only when we decide.
  required_version = "~> 1.16.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0" # exact build recorded in .terraform.lock.hcl (committed)
    }
  }

  # No backend on purpose: this root creates the bucket that holds the main
  # root's state, so its own state can't live there. It stays local and is
  # never committed (*.tfstate is in .gitignore).
}
