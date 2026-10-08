# The bucket that holds infra/terraform's state.
# Name: bucket names are global across all AWS accounts, so the account ID and
# region make it unique and say who owns it.

data "aws_caller_identity" "current" {}

locals {
  state_bucket = "shortify-tfstate-${data.aws_caller_identity.current.account_id}-${var.region}"
}

resource "aws_s3_bucket" "state" {
  bucket = local.state_bucket

  # Losing this bucket loses the record of every resource Terraform manages.
  lifecycle {
    prevent_destroy = true
  }
}

# Every state write keeps the previous version: a bad apply can be rolled back.
resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id

  versioning_configuration {
    status = "Enabled"
  }
}

# State holds resource IDs, ARNs and sometimes secrets: encrypted at rest.
resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# State is never public, whatever a later policy or ACL says.
resource "aws_s3_bucket_public_access_block" "state" {
  bucket = aws_s3_bucket.state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
