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
