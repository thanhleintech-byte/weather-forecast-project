output "eks_cluster_role_arn" {
  value = aws_iam_role.eks_cluster.arn
}

output "eks_node_role_arn" {
  value = aws_iam_role.eks_node.arn
}

output "lambda_authorizer_role_arn" {
  value = aws_iam_role.lambda_authorizer.arn
}
