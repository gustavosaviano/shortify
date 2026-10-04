# ── The Phase 4 app instance leaves Terraform (Phase 3b, option B) ──────────
# Releases launch and retire the app instances (scripts/release.sh), so Terraform
# stops tracking the one it launched in Phase 4, without destroying it: it's
# terminated through the API afterwards (edge case #62). Kept as the record of that
# move; on a state that never had the instance it does nothing.
removed {
  from = aws_instance.app

  lifecycle {
    destroy = false
  }
}

# ── App launch template (Phase 3b, option B) ─────────────────────────────────
# Each release launches its instance from this template (README, key decisions);
# Terraform owns only the stable configuration. The image is a release input passed
# at launch, so it isn't here. A direct RunInstances keeps the template's metadata
# options on Floci; an Auto Scaling launch doesn't (edge case #57). Rotating the
# admin key changes nothing here (same key name): only instances launched afterwards
# get the new key, so a rotation is followed by a release.
resource "aws_launch_template" "app" {
  name                   = "shortify-app"
  description            = "App instances: stable configuration; the image is a release input"
  instance_type          = "t3.micro"
  key_name               = aws_key_pair.admin.key_name
  vpc_security_group_ids = [aws_security_group.app.id]
  update_default_version = true

  iam_instance_profile {
    name = aws_iam_instance_profile.app.name # reads the DB secret (iam.tf)
  }

  # IMDSv2 only (edge case #49): users submit arbitrary URLs, so a future SSRF bug
  # must not turn into stolen instance credentials with a plain GET. Hop limit 1
  # keeps the token on the instance itself (not reachable through a Docker bridge).
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  tag_specifications {
    resource_type = "instance"

    tags = {
      Name      = "shortify-app"
      Project   = local.default_tags.Project
      ManagedBy = "release" # launched by the release process, never by Terraform
    }
  }

  tags = {
    Name = "shortify-app"
  }

  lifecycle {
    # Verify the effect, not the request (edge cases #36, #43).
    postcondition {
      condition     = self.metadata_options[0].http_tokens == "required"
      error_message = "IMDSv2 is not required in the app launch template: the API did not store http_tokens = required."
    }
  }
}
