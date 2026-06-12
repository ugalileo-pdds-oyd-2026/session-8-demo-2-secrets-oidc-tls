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

# db_password is GONE — the initial secret value is managed in modules/secrets.
# No plaintext credential exists as a Terraform variable in end/.

variable "domain_name" {
  type        = string
  description = "Domain name for the ACM TLS certificate (e.g. app.example.com)"
}

variable "route53_zone_id" {
  type        = string
  description = "Route 53 hosted zone ID for DNS validation records"
}
