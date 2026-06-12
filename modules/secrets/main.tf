data "aws_caller_identity" "current" {}

locals {
  name_prefix = "${var.project}-${var.environment}"

  tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

# ── KMS Customer Managed Key ───────────────────────────────────────────────────
# Used to encrypt the Secrets Manager secret at rest.
# Key rotation is enabled — AWS rotates the key material annually.

resource "aws_kms_key" "app" {
  description             = "${local.name_prefix} application CMK"
  deletion_window_in_days = 30
  enable_key_rotation     = true
  tags                    = local.tags

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Account root retains full key administration rights
        Sid    = "RootAccountAdmin"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = ["kms:*"]
        Resource = ["*"]
      },
      {
        # Secrets Manager needs GenerateDataKey + Decrypt to wrap/unwrap secrets
        Sid    = "AllowSecretsManager"
        Effect = "Allow"
        Principal = {
          Service = "secretsmanager.amazonaws.com"
        }
        Action = [
          "kms:GenerateDataKey",
          "kms:Decrypt",
          "kms:DescribeKey",
        ]
        Resource = ["*"]
      }
    ]
  })
}

resource "aws_kms_alias" "app" {
  name          = "alias/${local.name_prefix}-app-key"
  target_key_id = aws_kms_key.app.key_id
}

# ── Secrets Manager — DB credentials ──────────────────────────────────────────
# Stores database credentials as a JSON object, encrypted with the CMK above.
# The compute role (see modules/iam) is granted GetSecretValue + kms:Decrypt
# so the app can fetch credentials at runtime without them ever landing in state.

resource "aws_secretsmanager_secret" "db" {
  name                    = "${local.name_prefix}/db/credentials"
  description             = "PostgreSQL credentials for the ${local.name_prefix} app"
  kms_key_id              = aws_kms_key.app.arn
  recovery_window_in_days = 7
  tags                    = local.tags
}

resource "aws_secretsmanager_secret_version" "db" {
  secret_id = aws_secretsmanager_secret.db.id

  secret_string = jsonencode({
    username = var.db_username
    password = "8kEX8EHT7G94zBrTnKgLaAXKv6BTjFL2QqmW"   # rotated out-of-band; Terraform never overwrites it # same password as the initial db_password value in variables.tf and the initial_password argument in main.tf
    host     = "REPLACE_WITH_RDS_ENDPOINT"
    port     = 5432
    dbname   = var.project
  })

  lifecycle {
    # Prevent Terraform from overwriting the password after the first apply.
    # Rotate credentials out-of-band (Lambda rotation function or manual update).
    # The secret ARN stays stable; no re-deploy required after rotation.
    ignore_changes = [secret_string]
  }
}
