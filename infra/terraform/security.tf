# Security groups are empty shells; every rule is its own resource.
# That avoids dependency cycles (the groups reference each other) and makes each rule
# a separate, reviewable line in the plan.
#
# Note: Terraform removes AWS's default "allow all outbound" rule from groups it creates,
# so all egress below is explicit (least privilege by design).

resource "aws_security_group" "alb" {
  name        = "shortify-alb-sg"
  description = "Public entry point: HTTP/HTTPS from the internet"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "shortify-alb-sg" }
}

resource "aws_security_group" "app" {
  name        = "shortify-ec2-sg"
  description = "App instances: only reachable from the ALB (and SSH from the admin IP)"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "shortify-ec2-sg" }
}

resource "aws_security_group" "db" {
  name        = "shortify-rds-sg"
  description = "Database: only reachable from the app instances"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "shortify-rds-sg" }
}

# ── ALB ───────────────────────────────────────────────────────────────────────
resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  security_group_id = aws_security_group.alb.id
  description       = "Campaign links are public"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  security_group_id = aws_security_group.alb.id
  description       = "Campaign links are public"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "alb_to_app" {
  security_group_id            = aws_security_group.alb.id
  description                  = "Forward requests to the app"
  ip_protocol                  = "tcp"
  from_port                    = var.app_port
  to_port                      = var.app_port
  referenced_security_group_id = aws_security_group.app.id
}

# ── App instances ─────────────────────────────────────────────────────────────
resource "aws_vpc_security_group_ingress_rule" "app_from_alb" {
  security_group_id            = aws_security_group.app.id
  description                  = "Only the ALB may call the app"
  ip_protocol                  = "tcp"
  from_port                    = var.app_port
  to_port                      = var.app_port
  referenced_security_group_id = aws_security_group.alb.id
}

resource "aws_vpc_security_group_ingress_rule" "app_ssh_admin" {
  security_group_id = aws_security_group.app.id
  description       = "SSH from the admin IP only"
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
  cidr_ipv4         = var.admin_cidr
}

resource "aws_vpc_security_group_egress_rule" "app_to_db" {
  security_group_id            = aws_security_group.app.id
  description                  = "Database access"
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  referenced_security_group_id = aws_security_group.db.id
}

resource "aws_vpc_security_group_egress_rule" "app_https_out" {
  security_group_id = aws_security_group.app.id
  description       = "Package installs and release downloads"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "app_http_out" {
  security_group_id = aws_security_group.app.id
  description       = "Package mirrors that still use HTTP"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = "0.0.0.0/0"
}

# ── Database ──────────────────────────────────────────────────────────────────
resource "aws_vpc_security_group_ingress_rule" "db_from_app" {
  security_group_id            = aws_security_group.db.id
  description                  = "Only the app may reach the database"
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  referenced_security_group_id = aws_security_group.app.id
}
# No egress rules on the database: replies to allowed inbound connections are automatic (stateful).

# ── Floci workaround (off by default; never needed on real AWS) ──────────────
# The provider removes AWS's default allow-all egress rule by calling
# RevokeSecurityGroupEgress with IpProtocol=-1, FromPort=0, ToPort=0.
# Floci answers "true" but removes nothing: it matches on ports, and its default
# rule has none. On AWS, ports are ignored for protocol -1. Until Floci fixes this,
# revoke the rule without ports, then verify it's gone (fail the apply if not).
resource "terraform_data" "revoke_default_egress" {
  for_each = {
    for name, id in {
      alb = aws_security_group.alb.id
      app = aws_security_group.app.id
      db  = aws_security_group.db.id
    } : name => id if var.emulator_revoke_default_egress
  }

  triggers_replace = [each.value] # re-run whenever the group is recreated

  provisioner "local-exec" {
    command = <<-EOT
      set -eu
      aws ec2 revoke-security-group-egress --group-id ${each.value} \
        --ip-permissions 'IpProtocol=-1,IpRanges=[{CidrIp=0.0.0.0/0}]' > /dev/null || true
      left=$(aws ec2 describe-security-groups --group-ids ${each.value} \
        --query "length(SecurityGroups[0].IpPermissionsEgress[?IpProtocol=='-1'])" --output text)
      if [ "$left" != "0" ]; then
        echo "default allow-all egress rule still present on ${each.value}" >&2
        exit 1
      fi
    EOT
  }
}
