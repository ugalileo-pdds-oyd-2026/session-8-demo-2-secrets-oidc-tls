locals {
  name_prefix = "${var.project}-${var.environment}"

  tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

data "aws_caller_identity" "current" {}

# ── Compute role (EC2 instance profile) ───────────────────────────────────────

resource "aws_iam_role" "compute" {
  name = "${local.name_prefix}-compute-role"
  tags = local.tags

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_policy" "compute" {
  name = "${local.name_prefix}-compute-policy"
  tags = local.tags

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "CloudWatchLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = ["arn:aws:logs:*:*:*"]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "compute" {
  role       = aws_iam_role.compute.name
  policy_arn = aws_iam_policy.compute.arn
}

resource "aws_iam_instance_profile" "compute" {
  name = "${local.name_prefix}-compute-profile"
  role = aws_iam_role.compute.name
  tags = local.tags
}

# ── Secret-read policy — scoped to the specific secret + KMS key ───────────────
# This policy allows the EC2 app to call GetSecretValue at runtime.
# It is ATTACHED to the compute role below — not just defined (a common oversight).

resource "aws_iam_policy" "read_db_secret" {
  name = "${local.name_prefix}-read-db-secret"
  tags = local.tags

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "GetSecret"
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret",
        ]
        # Scoped to the exact secret ARN — not "Resource": ["*"]
        Resource = [var.db_secret_arn]
      },
      {
        Sid    = "DecryptWithCMK"
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:DescribeKey",
        ]
        # Scoped to the exact KMS key ARN
        Resource = [var.kms_key_arn]
      }
    ]
  })
}

# Attach the secret-read policy to the compute role.
# Without this attachment the policy has no effect — the role would still be denied.
resource "aws_iam_role_policy_attachment" "compute_read_secret" {
  role       = aws_iam_role.compute.name
  policy_arn = aws_iam_policy.read_db_secret.arn
}

# ── CI runner role — OIDC trust (replaces the account-root placeholder) ────────
#
# StringEquals (not StringLike) on the `sub` claim — a wildcard here would allow
# any repository in the org to assume this role.
#
# The `aud` condition is required: GitHub's OIDC provider sets audience to
# "sts.amazonaws.com" by default for aws-actions/configure-aws-credentials.

resource "aws_iam_role" "ci_runner" {
  name = "${local.name_prefix}-ci-runner-role"
  tags = local.tags

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = var.oidc_provider_arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = "repo:${var.github_repo}:ref:refs/heads/main"
        }
      }
    }]
  })
}

resource "aws_iam_policy" "ci_runner" {
  name = "${local.name_prefix}-ci-runner-policy"
  tags = local.tags

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "CallerIdentity"
        Effect   = "Allow"
        Action   = ["sts:GetCallerIdentity"]
        Resource = ["*"]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ci_runner" {
  role       = aws_iam_role.ci_runner.name
  policy_arn = aws_iam_policy.ci_runner.arn
}
