# ── App instance ─────────────────────────────────────────────────────────────
# Public subnet for direct SSH in this phase (known simplification, README).
# Replaced, never repaired: a new key must mean a new instance, because keys
# are only installed at launch (edge case #9); rotation then can't leave the
# old key trusted on a running server.
resource "aws_instance" "app" {
  ami                    = var.app_ami_id
  instance_type          = "t3.micro" # smallest current-generation general-purpose type
  subnet_id              = aws_subnet.this["public-01"].id
  vpc_security_group_ids = [aws_security_group.app.id]
  key_name               = aws_key_pair.admin.key_name

  tags = {
    Name = "shortify-app"
  }

  lifecycle {
    replace_triggered_by = [aws_key_pair.admin]
  }
}
