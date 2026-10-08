output "state_bucket" {
  description = "Bucket for infra/terraform's backend \"s3\" block."
  value       = aws_s3_bucket.state.bucket
}
