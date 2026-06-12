variable "project" {
  type = string
}

variable "environment" {
  type = string
}

variable "db_username" {
  type        = string
  description = "Database username — stored in the secret JSON as 'username'"
}
