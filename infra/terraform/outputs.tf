output "vpc_id" {
  description = "ID of the Shortify VPC."
  value       = aws_vpc.main.id
}

output "public_subnet_ids" {
  description = "Public subnets (ALB and app instances)."
  value       = local.public_subnet_ids
}

output "private_subnet_ids" {
  description = "Private subnets (RDS)."
  value       = local.private_subnet_ids
}
