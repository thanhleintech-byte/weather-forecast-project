variable "project_name" {
  type = string
}

variable "environment" {
  type = string
}

variable "jwt_secret_arn" {
  description = "ARN of the Secrets Manager secret containing the JWT signing key"
  type        = string
}

variable "lambda_role_arn" {
  type = string
}

variable "lambda_timeout" {
  type    = number
  default = 10
}

variable "lambda_memory_mb" {
  type    = number
  default = 128
}
