variable "project" {
  type = string
}

variable "environment" {
  type = string
}

variable "github_repo" {
  type        = string
  description = "GitHub repository in org/name format — used to scope the OIDC sub claim in end/"
}

variable "db_secret_arn" {
  type        = string
  description = "ARN of the Secrets Manager secret — scopes the GetSecretValue action"
  sensitive   = true
}

variable "kms_key_arn" {
  type        = string
  description = "ARN of the KMS CMK — scopes the kms:Decrypt action"
}
