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

# db_password is GONE. The app fetches credentials from Secrets Manager at runtime.
variable "db_secret_name" {
  type        = string
  description = "Secrets Manager secret name — injected as DB_SECRET_NAME (not a credential)"
}
