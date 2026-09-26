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

output "security_group_ids" {
  description = "Security groups by tier."
  value = {
    alb = aws_security_group.alb.id
    app = aws_security_group.app.id
    db  = aws_security_group.db.id
  }
}
