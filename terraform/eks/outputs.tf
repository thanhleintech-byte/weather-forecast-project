output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "cluster_certificate_authority_data" {
  value     = module.eks.cluster_certificate_authority_data
  sensitive = true
}

output "oidc_provider_arn" {
  value = module.eks.oidc_provider_arn
}

output "oidc_provider_url" {
  value = module.eks.oidc_provider_url
}

output "kubeconfig_command" {
  value = "aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks.cluster_name}"
}

output "ecr_repository_url" {
  value = module.ecr.repository_url
}

output "ecr_repository_arn" {
  value = module.ecr.repository_arn
}

output "app_irsa_role_arn" {
  value = aws_iam_role.app_irsa.arn
}

output "lambda_authorizer_role_arn" {
  value = module.iam.lambda_authorizer_role_arn
}

output "jenkins_irsa_role_arn" {
  value = module.eks.jenkins_irsa_role_arn
}

output "cluster_autoscaler_role_arn" {
  value = module.eks.cluster_autoscaler_role_arn
}

output "cloudwatch_log_group_app" {
  value = module.cloudwatch.log_group_app
}

output "cloudwatch_log_group_nginx" {
  value = module.cloudwatch.log_group_nginx
}
