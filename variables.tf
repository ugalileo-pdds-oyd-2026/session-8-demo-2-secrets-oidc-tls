variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "project" {
  type = string
}

variable "environment" {
  type    = string
  default = "dev"
}

variable "github_repo" {
  type        = string
  description = "GitHub repository in org/name format (e.g. my-org/my-repo)"
}

variable "db_username" {
  type    = string
  default = "appuser"
}

# ⚠️  Plaintext DB password — the security gap this demo closes.
# This value is passed through user_data and lands in terraform.tfstate in cleartext.
variable "db_password" {
  type        = string
  sensitive   = true
  description = "Database password — stored in state. Replaced by Secrets Manager in end/."
}
