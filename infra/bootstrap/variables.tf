variable "region" {
  description = "Region of the state bucket. Must match the region in infra/terraform's backend."
  type        = string
  default     = "us-east-1"
}
