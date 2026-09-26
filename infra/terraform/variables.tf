variable "region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "us-east-1"
}

variable "vpc_cidr" {
  description = "CIDR block of the VPC. /16 leaves room to grow; the primary CIDR can't be changed later."
  type        = string
  default     = "10.0.0.0/16"
}

variable "subnets" {
  description = "Subnets to create: two tiers x two AZs."
  type = map(object({
    cidr   = string
    az     = string
    public = bool
  }))
  default = {
    "public-01"  = { cidr = "10.0.1.0/24", az = "us-east-1a", public = true }
    "public-02"  = { cidr = "10.0.2.0/24", az = "us-east-1b", public = true }
    "private-01" = { cidr = "10.0.3.0/24", az = "us-east-1a", public = false }
    "private-02" = { cidr = "10.0.4.0/24", az = "us-east-1b", public = false }
  }
}
