data "aws_caller_identity" "current" {}

# ---------------------------------------------------------------------------
# Read network stage outputs
# ---------------------------------------------------------------------------

data "terraform_remote_state" "network" {
  backend = "local"
  config = {
    path = "../network/terraform.tfstate"
  }
}

# ---------------------------------------------------------------------------
# IAM — base roles
# ---------------------------------------------------------------------------

module "iam" {
  source = "../modules/iam"

  project_name   = var.project_name
  environment    = var.environment
  aws_account_id = data.aws_caller_identity.current.account_id
}

# ---------------------------------------------------------------------------
# EKS cluster
# ---------------------------------------------------------------------------

module "eks" {
  source = "../modules/eks"

  project_name         = var.project_name
  environment          = var.environment
  kubernetes_version   = var.kubernetes_version
  vpc_id               = data.terraform_remote_state.network.outputs.vpc_id
  private_subnet_ids   = data.terraform_remote_state.network.outputs.private_subnet_ids
  public_subnet_ids    = data.terraform_remote_state.network.outputs.public_subnet_ids
  eks_cluster_role_arn = module.iam.eks_cluster_role_arn
  eks_node_role_arn    = module.iam.eks_node_role_arn
  node_instance_type   = var.node_instance_type
  node_min_size        = var.node_min_size
  node_max_size        = var.node_max_size
  node_desired_size    = var.node_desired_size
}

# ---------------------------------------------------------------------------
# ECR — container registry for the app image
# ---------------------------------------------------------------------------

module "ecr" {
  source = "../modules/ecr"

  project_name          = var.project_name
  environment           = var.environment
  image_retention_count = var.ecr_image_retention_count
}

# ---------------------------------------------------------------------------
# CloudWatch — log groups + alarms
# ---------------------------------------------------------------------------

module "cloudwatch" {
  source = "../modules/cloudwatch"

  project_name          = var.project_name
  environment           = var.environment
  log_retention_days    = var.log_retention_days
  error_alarm_threshold = var.error_alarm_threshold
}

# ---------------------------------------------------------------------------
# IRSA — role assumed by the max-weather-sa ServiceAccount in the cluster.
# Created here (not in modules/iam) because it depends on the EKS OIDC
# provider, which is created by modules/eks.
# ---------------------------------------------------------------------------

resource "aws_iam_role" "app_irsa" {
  name = "${var.project_name}-${var.environment}-app-irsa-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = module.eks.oidc_provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${module.eks.oidc_provider_url}:sub" = "system:serviceaccount:max-weather:max-weather-sa"
          "${module.eks.oidc_provider_url}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

resource "aws_iam_policy" "cloudwatch_write" {
  name        = "${var.project_name}-${var.environment}-cloudwatch-write"
  description = "Allow app pods to write structured logs to CloudWatch"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogStreams",
      ]
      Resource = "arn:aws:logs:*:${data.aws_caller_identity.current.account_id}:log-group:/eks/${var.project_name}/*"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "app_irsa_cloudwatch" {
  role       = aws_iam_role.app_irsa.name
  policy_arn = aws_iam_policy.cloudwatch_write.arn
}
