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

variable "app_port" {
  description = "Port the app listens on inside the instances."
  type        = number
  default     = 8000
}

variable "admin_cidr" {
  description = "CIDR allowed to SSH to the instances, e.g. \"203.0.113.10/32\". Set it in terraform.tfvars (git-ignored), never in code: the repo is public."
  type        = string
}

variable "ssh_public_key" {
  description = "Public key installed on the app instances (contents of the .pub file). Set it in terraform.tfvars locally and via TF_VAR_ssh_public_key in the pipeline; never a path, so the code doesn't depend on one machine's filesystem."
  type        = string

  validation {
    condition     = can(regex("^ssh-ed25519 [A-Za-z0-9+/=]+( .*)?$", var.ssh_public_key))
    error_message = "ssh_public_key must be an ed25519 public key (the contents of the .pub file, not a path or a private key)."
  }
}

variable "emulator_revoke_default_egress" {
  description = "Floci-only workaround: remove the default allow-all egress rule that Floci fails to remove (it matches revoke requests on ports; AWS ignores ports for protocol -1). Keep false on real AWS."
  type        = bool
  default     = false
}

variable "emulator_rds_unsupported_settings" {
  description = "Floci-only workaround: Floci doesn't implement RDS deletion protection and only stores gp2 storage (docs/edge-cases.md #43), so every plan would show a change. When true, request what Floci can store. Keep false on real AWS."
  type        = bool
  default     = false
}

variable "emulator_key_pair_create_tags" {
  description = "Floci-only workaround: Floci drops the tags sent with ImportKeyPair but stores tags added afterwards with CreateTags (docs/edge-cases.md #47). When true, tag the key pair right after it's created and verify every tag. Keep false on real AWS."
  type        = bool
  default     = false
}
