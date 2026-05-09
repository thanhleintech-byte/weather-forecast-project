locals {
  name_prefix = "${var.project_name}-${var.environment}"
}

# ---------------------------------------------------------------------------
# Log Groups
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "app" {
  name              = "/eks/${var.project_name}/application"
  retention_in_days = var.log_retention_days

  tags = {
    Name        = "${local.name_prefix}-app-logs"
    Environment = var.environment
  }
}

resource "aws_cloudwatch_log_group" "nginx" {
  name              = "/eks/${var.project_name}/nginx"
  retention_in_days = var.log_retention_days

  tags = {
    Name        = "${local.name_prefix}-nginx-logs"
    Environment = var.environment
  }
}

resource "aws_cloudwatch_log_group" "lambda_authorizer" {
  name              = "/aws/lambda/${var.project_name}-authorizer"
  retention_in_days = var.log_retention_days

  tags = {
    Name        = "${local.name_prefix}-lambda-logs"
    Environment = var.environment
  }
}

# ---------------------------------------------------------------------------
# Metric Filters — extract error counts from structured JSON logs
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_log_metric_filter" "error_count" {
  name           = "${local.name_prefix}-error-count"
  log_group_name = aws_cloudwatch_log_group.app.name
  pattern        = "{ $.levelname = \"ERROR\" }"

  metric_transformation {
    name          = "MaxWeatherErrorCount"
    namespace     = "MaxWeather/${var.environment}"
    value         = "1"
    default_value = "0"
    unit          = "Count"
  }
}

resource "aws_cloudwatch_log_metric_filter" "auth_rejection" {
  name           = "${local.name_prefix}-auth-rejection"
  log_group_name = aws_cloudwatch_log_group.app.name
  pattern        = "{ $.message = \"token_rejected\" }"

  metric_transformation {
    name          = "MaxWeatherAuthRejections"
    namespace     = "MaxWeather/${var.environment}"
    value         = "1"
    default_value = "0"
    unit          = "Count"
  }
}

# ---------------------------------------------------------------------------
# Alarms
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "high_error_rate" {
  alarm_name          = "${local.name_prefix}-high-error-rate"
  alarm_description   = "Triggered when app generates more than ${var.error_alarm_threshold} ERROR logs in 5 minutes"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "MaxWeatherErrorCount"
  namespace           = "MaxWeather/${var.environment}"
  period              = 300
  statistic           = "Sum"
  threshold           = var.error_alarm_threshold
  treat_missing_data  = "notBreaching"

  alarm_actions = var.alarm_actions
  ok_actions    = var.alarm_actions

  tags = {
    Name        = "${local.name_prefix}-high-error-rate"
    Environment = var.environment
  }
}

resource "aws_cloudwatch_metric_alarm" "high_auth_rejections" {
  alarm_name          = "${local.name_prefix}-high-auth-rejections"
  alarm_description   = "Triggered when auth rejection rate exceeds 50 in 5 minutes — possible brute-force attempt"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "MaxWeatherAuthRejections"
  namespace           = "MaxWeather/${var.environment}"
  period              = 300
  statistic           = "Sum"
  threshold           = 50
  treat_missing_data  = "notBreaching"

  alarm_actions = var.alarm_actions
  ok_actions    = var.alarm_actions

  tags = {
    Name        = "${local.name_prefix}-high-auth-rejections"
    Environment = var.environment
  }
}
