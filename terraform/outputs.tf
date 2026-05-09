output "vpc_id" {
  description = "VPC ID"
  value       = module.vpc.vpc_id
}

output "eks_cluster_name" {
  description = "EKS cluster name"
  value       = module.eks.cluster_name
}

output "eks_cluster_endpoint" {
  description = "EKS API server endpoint"
  value       = module.eks.cluster_endpoint
}

output "eks_kubeconfig_command" {
  description = "Command to update local kubeconfig"
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks.cluster_name}"
}

output "ecr_repository_url" {
  description = "ECR repository URL — use this as the image prefix in Kubernetes manifests"
  value       = module.ecr.repository_url
}

output "app_irsa_role_arn" {
  description = "IRSA role ARN — annotate the max-weather-sa ServiceAccount with this"
  value       = aws_iam_role.app_irsa.arn
}

output "lambda_authorizer_arn" {
  description = "ARN of the Lambda authorizer — configure this in API Gateway"
  value       = module.lambda_authorizer.function_arn
}

output "cloudwatch_log_group_app" {
  description = "CloudWatch log group for application logs"
  value       = module.cloudwatch.log_group_app
}

output "cloudwatch_log_group_nginx" {
  description = "CloudWatch log group for Nginx ingress logs"
  value       = module.cloudwatch.log_group_nginx
}
