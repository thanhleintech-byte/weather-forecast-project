output "api_gateway_url" {
  description = "Invoke URL of the API Gateway prod stage — base URL for all API calls"
  value       = module.api_gateway.invoke_url
}

output "lambda_authorizer_arn" {
  value = module.lambda_authorizer.function_arn
}

output "jwt_secret_arn" {
  value = aws_secretsmanager_secret.jwt.arn
}
