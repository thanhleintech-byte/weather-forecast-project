variable "aws_region" {
  description = "AWS region to deploy all resources into"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Deployment environment (production, staging)"
  type        = string
  default     = "production"

  validation {
    condition     = contains(["production", "staging"], var.environment)
    error_message = "environment must be 'production' or 'staging'."
  }
}

variable "project_name" {
  description = "Project identifier used to name all resources"
  type        = string
  default     = "max-weather"
}

# ---------------------------------------------------------------------------
# VPC
# ---------------------------------------------------------------------------

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for the public subnets (one per AZ)"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for the private subnets (one per AZ, for EKS nodes)"
  type        = list(string)
  default     = ["10.0.3.0/24", "10.0.4.0/24"]
}

variable "single_nat_gateway" {
  description = "Use a single NAT Gateway (cost saving) instead of one per AZ"
  type        = bool
  default     = false
}

# ---------------------------------------------------------------------------
# EKS
# ---------------------------------------------------------------------------

variable "kubernetes_version" {
  description = "Kubernetes version for the EKS cluster"
  type        = string
  default     = "1.32"
}

variable "node_instance_type" {
  description = "EC2 instance type for EKS worker nodes"
  type        = string
  default     = "t3.medium"
}

variable "node_min_size" {
  description = "Minimum number of EKS worker nodes"
  type        = number
  default     = 2
}

variable "node_max_size" {
  description = "Maximum number of EKS worker nodes"
  type        = number
  default     = 10
}

variable "node_desired_size" {
  description = "Desired number of EKS worker nodes at launch"
  type        = number
  default     = 2
}

# ---------------------------------------------------------------------------
# ECR
# ---------------------------------------------------------------------------

variable "ecr_image_retention_count" {
  description = "Number of tagged images to retain in ECR"
  type        = number
  default     = 10
}

# ---------------------------------------------------------------------------
# CloudWatch
# ---------------------------------------------------------------------------

variable "log_retention_days" {
  description = "Number of days to retain CloudWatch logs"
  type        = number
  default     = 30
}

variable "error_alarm_threshold" {
  description = "Number of ERROR log events per 5 minutes that triggers an alarm"
  type        = number
  default     = 10
}

# ---------------------------------------------------------------------------
# Lambda Authorizer
# ---------------------------------------------------------------------------

variable "jwt_secret_arn" {
  description = "ARN of the AWS Secrets Manager secret containing the JWT signing secret"
  type        = string
}

# ---------------------------------------------------------------------------
# Add-ons — ArgoCD + Jenkins
# ---------------------------------------------------------------------------

variable "github_repo_url" {
  description = "HTTPS URL of the GitHub repository used by ArgoCD and Jenkins"
  type        = string
  default     = "https://github.com/thanhleintech-byte/weather-forecast-project.git"
}

variable "github_username" {
  description = "GitHub username that owns the repository"
  type        = string
  default     = "thanhleintech-byte"
}

variable "github_pat" {
  description = "GitHub Personal Access Token (repo scope) for Jenkins pipeline access"
  type        = string
  sensitive   = true
}

variable "aws_access_key_id" {
  description = "AWS access key ID used by Jenkins for ECR push and EKS deploy"
  type        = string
  sensitive   = true
}

variable "aws_secret_access_key" {
  description = "AWS secret access key used by Jenkins for ECR push and EKS deploy"
  type        = string
  sensitive   = true
}

# ---------------------------------------------------------------------------
# API Gateway
# ---------------------------------------------------------------------------

variable "app_host" {
  description = "Public hostname of the max-weather app (Nginx Ingress ALB, no scheme) — used as HTTP_PROXY backend for API Gateway"
  type        = string
  default     = "max-weather.workaholic.dpdns.org"
}
