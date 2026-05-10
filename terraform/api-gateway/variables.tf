variable "aws_region" {
  type    = string
  default = "ap-south-1"
}

variable "project_name" {
  type    = string
  default = "max-weather"
}

variable "environment" {
  type    = string
  default = "production"
}

variable "app_host" {
  description = "Public hostname of the max-weather app (Nginx ingress, no scheme) — used as the HTTP_PROXY backend for API Gateway"
  type        = string
}

variable "jwt_secret_value" {
  description = "Plaintext JWT signing key. Terraform writes it to AWS Secrets Manager, which the Lambda authorizer reads at runtime."
  type        = string
  sensitive   = true
}
