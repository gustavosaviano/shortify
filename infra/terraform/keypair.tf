# ── Key pair: admin SSH to the app instances ─────────────────────────────────
# Only the public key goes to AWS; the private key never leaves the admin's
# machine. The contents come from var.ssh_public_key (never a file path).
# AWS can't update a key pair's material, so a new key replaces this resource;
# the instance uses replace_triggered_by on it, because keys are only
# installed at launch (a rotation must never leave the old key trusted).
locals {
  key_pair_tags = {
    Name = "shortify-admin"
  }
}

resource "aws_key_pair" "admin" {
  key_name   = "shortify-admin"
  public_key = var.ssh_public_key
  tags       = local.key_pair_tags
}

# ── Floci workaround (off by default; never needed on real AWS) ──────────────
# Floci ignores the tags in ImportKeyPair (TagSpecifications), so every newly
# created key pair would show a tag diff until a second apply. CreateTags works,
# so tag it right after creation, then check each tag and fail the apply if any
# is missing. Re-runs whenever the key pair is replaced (e.g. a key rotation).
#
# The expected tags come from the configuration, never from
# aws_key_pair.admin.tags_all: after create, that attribute holds what the API
# returned, which is exactly the set of tags Floci dropped (empty).
locals {
  key_pair_expected_tags = merge(local.default_tags, local.key_pair_tags)
}

resource "terraform_data" "key_pair_tags" {
  count = var.emulator_key_pair_create_tags ? 1 : 0

  triggers_replace = [aws_key_pair.admin.key_pair_id]

  lifecycle {
    # A check that iterates over nothing verifies nothing.
    precondition {
      condition     = length(local.key_pair_expected_tags) > 0
      error_message = "No expected tags for the key pair: the tag check would verify nothing."
    }
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -eu
      aws ec2 create-tags --resources ${aws_key_pair.admin.key_pair_id} --tags %{for k, v in local.key_pair_expected_tags}'Key=${k},Value=${v}' %{endfor}
      %{for k, v in local.key_pair_expected_tags~}
      got=$(aws ec2 describe-key-pairs --key-names ${aws_key_pair.admin.key_name} --query "KeyPairs[0].Tags[?Key=='${k}'].Value | [0]" --output text)
      [ "$got" = '${v}' ] || { echo "tag ${k} missing on key pair ${aws_key_pair.admin.key_name}" >&2; exit 1; }
      %{endfor~}
    EOT
  }
}
