# ── VPC ──────────────────────────────────────────────────────────────────────
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "shortify-vpc"
  }
}

# ── Subnets: one block, four instances (for_each over var.subnets) ───────────
resource "aws_subnet" "this" {
  for_each = var.subnets

  vpc_id                  = aws_vpc.main.id # this reference is what orders subnet after VPC
  cidr_block              = each.value.cidr
  availability_zone       = each.value.az # always explicit: never let AWS pick
  map_public_ip_on_launch = each.value.public

  tags = {
    Name = "shortify-${each.key}"
    Tier = each.value.public ? "public" : "private"
  }
}

locals {
  public_subnet_ids  = [for k, s in aws_subnet.this : s.id if var.subnets[k].public]
  private_subnet_ids = [for k, s in aws_subnet.this : s.id if !var.subnets[k].public]
}

# ── Internet gateway: the VPC's door to the internet ─────────────────────────
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id # attached to the VPC as part of creation

  tags = {
    Name = "shortify-igw"
  }
}

# ── Route tables: public (to the IGW) and an explicit private one ────────────
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "shortify-public-route"
  }
}

# Explicit instead of relying on the main table: adding an internet route to the
# main table would silently make every implicitly associated subnet public.
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "shortify-private-route"
  }
}

resource "aws_route_table_association" "this" {
  for_each = aws_subnet.this

  subnet_id      = each.value.id
  route_table_id = var.subnets[each.key].public ? aws_route_table.public.id : aws_route_table.private.id
}
