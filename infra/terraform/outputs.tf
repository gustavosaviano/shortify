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

output "db_endpoint" {
  description = "Database host and port. On Floci the address is a container IP the host cannot reach: connect to localhost on this port (edge case #14)."
  value = {
    address = aws_db_instance.db.address
    port    = aws_db_instance.db.port
  }
}

output "db_master_secret_arn" {
  description = "ARN of the RDS-managed secret holding the master password (never the password itself)."
  value       = aws_db_instance.db.master_user_secret[0].secret_arn
}

output "alb_dns_name" {
  description = "Public DNS name of the ALB. On Floci it resolves to ::1 (edge case #24)."
  value       = aws_lb.main.dns_name
}

output "target_group_arn" {
  description = "Target group the deploy pipeline registers instances in (Phase 3b)."
  value       = aws_lb_target_group.app.arn
}

output "instance_id" {
  description = "ID of the app instance. On Floci, SSH is on a host port: docker port floci-ec2-<id> 22/tcp (edge case #21)."
  value       = aws_instance.app.id
}
