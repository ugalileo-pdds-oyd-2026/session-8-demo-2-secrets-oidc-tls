variable "project" {
  type = string
}

variable "environment" {
  type = string
}

variable "vpc_id" {
  type        = string
  description = "VPC in which to create the DB security group"
}

variable "subnet_ids" {
  type        = list(string)
  description = "Subnet IDs for the DB subnet group (must span at least two AZs)"
}

variable "app_sg_id" {
  type        = string
  description = "App instance security group — only source allowed to reach port 5432"
}

variable "db_name" {
  type        = string
  description = "Initial database name"
}

variable "db_username" {
  type        = string
  description = "Master username"
}

variable "db_password" {
  type        = string
  sensitive   = true
  description = "Master password — plaintext in state. Rotated via Secrets Manager in end/."
}
