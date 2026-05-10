# ---------------------------------------------------------------------------
# Read EKS stage outputs (only needed: lambda_authorizer_role_arn)
# ---------------------------------------------------------------------------

data "terraform_remote_state" "eks" {
  backend = "local"
  config = {
    path = "../eks/terraform.tfstate"
  }
}

# ---------------------------------------------------------------------------
# JWT signing key — terraform owns the Secrets Manager resource so the
# value in credentials.local.env is the single source of truth.
# ---------------------------------------------------------------------------

resource "aws_secretsmanager_secret" "jwt" {
  name                    = "${var.project_name}/jwt-secret"
  description             = "JWT signing key shared by the FastAPI app and the Lambda authorizer"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "jwt" {
  secret_id     = aws_secretsmanager_secret.jwt.id
  secret_string = var.jwt_secret_value
}

# ---------------------------------------------------------------------------
# Lambda authorizer — JWT validation for API Gateway
# ---------------------------------------------------------------------------

module "lambda_authorizer" {
  source = "../modules/lambda_authorizer"

  project_name    = var.project_name
  environment     = var.environment
  jwt_secret_arn  = aws_secretsmanager_secret.jwt.arn
  lambda_role_arn = data.terraform_remote_state.eks.outputs.lambda_authorizer_role_arn
}

# ---------------------------------------------------------------------------
# API Gateway — public REST API in front of the EKS-hosted FastAPI app
# ---------------------------------------------------------------------------

module "api_gateway" {
  source = "../modules/api_gateway"

  project_name                 = var.project_name
  environment                  = var.environment
  aws_region                   = var.aws_region
  lambda_authorizer_arn        = module.lambda_authorizer.function_arn
  lambda_authorizer_invoke_arn = module.lambda_authorizer.invoke_arn
  app_host                     = var.app_host
}
