# ── Database ─────────────────────────────────────────────────────────────────
# RDS can't be placed in a subnet directly: it takes a DB subnet group
# (at least two AZs). Private subnets only: the database is never reachable
# from the internet.
resource "aws_db_subnet_group" "db" {
  name        = "shortify-rds"
  description = "Private subnets only"
  subnet_ids  = local.private_subnet_ids

  tags = {
    Name = "shortify-rds"
  }
}

resource "aws_db_instance" "db" {
  identifier     = "shortify-db"
  engine         = "postgres"
  engine_version = "16" # same major as CI's postgres:16; minor patches applied by AWS
  instance_class = "db.t3.micro"

  allocated_storage = 20
  # Floci only stores gp2 (docs/edge-cases.md #43)
  storage_type      = var.emulator_rds_unsupported_settings ? "gp2" : "gp3"
  storage_encrypted = true

  db_name                     = "shortify"
  username                    = "shortify"
  manage_master_user_password = true # RDS keeps the password in Secrets Manager (edge case #41)

  db_subnet_group_name   = aws_db_subnet_group.db.name
  vpc_security_group_ids = [aws_security_group.db.id]
  publicly_accessible    = false
  multi_az               = false # cost; production would enable it

  backup_retention_period = 7
  # Layer 1: the AWS API refuses to delete it. Floci doesn't implement it (#43),
  # so on Floci only prevent_destroy below protects the database.
  deletion_protection       = !var.emulator_rds_unsupported_settings
  skip_final_snapshot       = false
  final_snapshot_identifier = "shortify-db-final"
  delete_automated_backups  = false # keep backups even if the instance is ever deleted
  copy_tags_to_snapshot     = true

  tags = {
    Name = "shortify-db"
  }

  lifecycle {
    prevent_destroy = true # layer 2: Terraform refuses to plan a destroy

    # Verify the effect, not the request: fail if the API doesn't report protection on.
    postcondition {
      condition     = var.emulator_rds_unsupported_settings || self.deletion_protection
      error_message = "Deletion protection is not enabled on shortify-db: the API did not store it."
    }
  }
}
