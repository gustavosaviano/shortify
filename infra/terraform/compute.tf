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
  iam_instance_profile   = aws_iam_instance_profile.app.name # reads the DB secret (iam.tf)

  # IMDSv2 only (edge case #49): users submit arbitrary URLs, so a future SSRF bug
  # must not turn into stolen instance credentials with a plain GET. Hop limit 1
  # keeps the token on the instance itself (not reachable through a Docker bridge).
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  tags = {
    Name = "shortify-app"
  }

  lifecycle {
    replace_triggered_by = [aws_key_pair.admin]

    # Verify the effect, not the request (edge cases #36, #43).
    postcondition {
      condition     = self.metadata_options[0].http_tokens == "required"
      error_message = "IMDSv2 is not required on the app instance: the API did not store http_tokens = required."
    }
  }
}
