# ── App instance role: read the database secret, nothing else ────────────────
# A role, not access keys: on AWS the instance gets short-lived credentials
# through IMDSv2 (edge case #49), so there is nothing to store or leak.
# On Floci the policy is stored but not enforced: least privilege is validated
# on AWS only.
data "aws_iam_policy_document" "app_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "app" {
  name               = "shortify-app"
  assume_role_policy = data.aws_iam_policy_document.app_assume.json
}

# One action on one resource: a compromised app can read its own database
# password and nothing else. Inline: it belongs to this role only.
data "aws_iam_policy_document" "app_read_db_secret" {
  statement {
    sid       = "ReadDatabaseSecret"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_db_instance.db.master_user_secret[0].secret_arn]
  }
}

resource "aws_iam_role_policy" "app_read_db_secret" {
  name   = "read-db-secret"
  role   = aws_iam_role.app.id
  policy = data.aws_iam_policy_document.app_read_db_secret.json
}

# EC2 can't take a role directly, only an instance profile.
resource "aws_iam_instance_profile" "app" {
  name = "shortify-app"
  role = aws_iam_role.app.name

  # Floci 2.1.0 can't hold instance-profile tags (TagInstanceProfile is silently
  # ignored, ListInstanceProfileTags is unsupported), so the plan would never be
  # clean. No API path exists for a self-verifying workaround (unlike #47), and
  # ignore_changes can't be conditional: tag drift on this one resource is ignored
  # everywhere. On AWS its tags are still set at creation; only later default_tags
  # changes won't reach it.
  lifecycle {
    ignore_changes = [tags_all]
  }
}
