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
# Attached to the app EC2 instance. Grants CloudWatch Logs write access.
# In end/, this role gains a scoped secretsmanager:GetSecretValue + kms:Decrypt policy.

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

# ── CI runner role (GitHub Actions) ───────────────────────────────────────────
# start/: account-root trust — the insecure "stored key" baseline.
# end/:   trust replaced with OIDC AssumeRoleWithWebIdentity, scoped to
#         repo:<org>/<repo>:ref:refs/heads/main using StringEquals (not StringLike).

resource "aws_iam_role" "ci_runner" {
  name = "${local.name_prefix}-ci-runner-role"
  tags = local.tags

  # ⚠️ Account-root trust means any IAM principal in this account can assume this role.
  # The OIDC upgrade in end/ locks this to a single GitHub repository + branch.
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
      Action    = "sts:AssumeRole"
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
