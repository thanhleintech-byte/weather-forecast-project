variable "aws_region" {
  type = string
}

variable "cluster_name" {
  type = string
}

variable "github_repo_url" {
  type = string
}

variable "github_username" {
  type = string
}

variable "github_pat" {
  type      = string
  sensitive = true
}

variable "aws_access_key_id" {
  type      = string
  sensitive = true
}

variable "aws_secret_access_key" {
  type      = string
  sensitive = true
}

variable "jenkins_irsa_role_arn" {
  type = string
}

variable "jwt_secret_arn" {
  type = string
}
