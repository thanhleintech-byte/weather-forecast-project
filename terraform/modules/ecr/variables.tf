variable "project_name" {
  type = string
}

variable "environment" {
  type = string
}

variable "image_retention_count" {
  type    = number
  default = 10
}
