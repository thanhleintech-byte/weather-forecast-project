locals {
  function_name = "${var.project_name}-authorizer-${var.environment}"
  source_dir    = "${path.module}/../../../lambda/authorizer"
}

# Run `npm ci --omit=dev` before archiving so the zip ships with node_modules.
# Without this the deployed Lambda fails with "Cannot find module 'jsonwebtoken'".
# Triggers off package-lock.json (or package.json) hash so re-installs only
# happen when dependencies change.
resource "null_resource" "npm_install" {
  triggers = {
    package_hash = filesha256(
      fileexists("${local.source_dir}/package-lock.json")
        ? "${local.source_dir}/package-lock.json"
        : "${local.source_dir}/package.json"
    )
  }

  provisioner "local-exec" {
    working_dir = local.source_dir
    command = fileexists("${local.source_dir}/package-lock.json") ? "npm ci --omit=dev" : "npm install --omit=dev"
  }
}

data "archive_file" "authorizer" {
  type        = "zip"
  source_dir  = local.source_dir
  output_path = "${path.module}/authorizer.zip"

  depends_on = [null_resource.npm_install]
}

resource "aws_lambda_function" "authorizer" {
  function_name = local.function_name
  role          = var.lambda_role_arn
  handler       = "index.handler"
  runtime       = "nodejs20.x"
  filename      = data.archive_file.authorizer.output_path
  source_code_hash = data.archive_file.authorizer.output_base64sha256

  timeout     = var.lambda_timeout
  memory_size = var.lambda_memory_mb

  environment {
    variables = {
      JWT_SECRET_ARN = var.jwt_secret_arn
      JWT_ISSUER     = "max-weather"
      JWT_AUDIENCE   = "max-weather-api"
    }
  }

  tags = {
    Name        = local.function_name
    Environment = var.environment
  }
}

resource "aws_lambda_permission" "api_gateway" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.authorizer.function_name
  principal     = "apigateway.amazonaws.com"
}
