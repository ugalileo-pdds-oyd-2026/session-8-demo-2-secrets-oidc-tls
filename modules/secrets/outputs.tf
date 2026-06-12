output "kms_key_arn" {
  description = "ARN of the KMS CMK — used to grant kms:Decrypt to the compute role"
  value       = aws_kms_key.app.arn
}

output "kms_key_alias" {
  description = "KMS key alias"
  value       = aws_kms_alias.app.name
}

output "db_secret_arn" {
  description = "ARN of the Secrets Manager secret — used to scope secretsmanager:GetSecretValue"
  value       = aws_secretsmanager_secret.db.arn
  sensitive   = true
}

output "db_secret_name" {
  description = "Name of the Secrets Manager secret — injected into EC2 user_data as DB_SECRET_NAME"
  value       = aws_secretsmanager_secret.db.name
}
