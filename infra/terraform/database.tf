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
