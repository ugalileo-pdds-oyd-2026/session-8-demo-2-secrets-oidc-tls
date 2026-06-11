variable "project" {
  type = string
}

variable "environment" {
  type = string
}

variable "subnet_id" {
  type        = string
  description = "Subnet in which to launch the EC2 instance"
}

variable "app_sg_id" {
  type        = string
  description = "Security group ID for the app instance (created at root level)"
}

variable "alb_target_group_arn" {
  type        = string
  description = "Target group ARN — the instance is registered here at launch"
}

variable "instance_profile_name" {
  type        = string
  description = "IAM instance profile name from the iam module"
}

variable "db_host" {
  type        = string
  description = "RDS endpoint — injected into user_data as DB_HOST"
}

variable "db_name" {
  type        = string
  description = "Database name"
}

variable "db_username" {
  type        = string
  description = "Database username"
}

# ⚠️  Plaintext password — injected into user_data and stored in terraform.tfstate.
# Removed in end/ (replaced by db_secret_name).
variable "db_password" {
  type        = string
  sensitive   = true
  description = "Database password — plaintext. Eliminated by Secrets Manager in end/."
}
