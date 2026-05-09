variable "project_name" {
  type = string
}

variable "environment" {
  type = string
}

variable "log_retention_days" {
  type    = number
  default = 30
}

variable "error_alarm_threshold" {
  type    = number
  default = 10
}

variable "alarm_actions" {
  description = "List of SNS topic ARNs to notify on alarm (optional)"
  type        = list(string)
  default     = []
}
