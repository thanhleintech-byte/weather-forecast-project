terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.40"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }

  # Uncomment to use S3 backend for team collaboration
  # backend "s3" {
  #   bucket         = "max-weather-terraform-state"
  #   key            = "terraform.tfstate"
  #   region         = var.aws_region
  #   encrypt        = true
  #   dynamodb_table = "max-weather-terraform-locks"
  # }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "max-weather"
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}
