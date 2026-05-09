variable "project_name" {
  type = string
}

variable "environment" {
  type = string
}

variable "aws_region" {
  type = string
}

variable "lambda_authorizer_invoke_arn" {
  type = string
}

variable "lambda_authorizer_arn" {
  type = string
}

variable "app_host" {
  type        = string
  description = "Public hostname of the max-weather app (no scheme)"
  default     = "max-weather.workaholic.dpdns.org"
}
