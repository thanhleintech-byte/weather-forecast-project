output "log_group_app" {
  value = aws_cloudwatch_log_group.app.name
}

output "log_group_nginx" {
  value = aws_cloudwatch_log_group.nginx.name
}

output "log_group_lambda" {
  value = aws_cloudwatch_log_group.lambda_authorizer.name
}

output "error_metric_name" {
  value = "MaxWeatherErrorCount"
}
