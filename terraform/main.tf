data "aws_availability_zones" "available" {
  state = "available"
}

# ---------------------------------------------------------------------------
# VPC — networking foundation
# ---------------------------------------------------------------------------

module "vpc" {
  source = "./modules/vpc"

  project_name         = var.project_name
  environment          = var.environment
  vpc_cidr             = var.vpc_cidr
  public_subnet_cidrs  = var.public_subnet_cidrs
  private_subnet_cidrs = var.private_subnet_cidrs
  availability_zones   = slice(data.aws_availability_zones.available.names, 0, length(var.public_subnet_cidrs))
  single_nat_gateway   = var.single_nat_gateway
}

# ---------------------------------------------------------------------------
# IAM — base roles (cluster, nodes, Lambda) created before EKS to avoid cycle
# ---------------------------------------------------------------------------

module "iam" {
  source = "./modules/iam"

  project_name   = var.project_name
  environment    = var.environment
  aws_account_id = data.aws_caller_identity.current.account_id
}

data "aws_caller_identity" "current" {}

# ---------------------------------------------------------------------------
# Helm provider — authenticates to EKS using the AWS CLI token exchange
# ---------------------------------------------------------------------------

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.aws_region]
    }
  }
}

# ---------------------------------------------------------------------------
# IRSA Role — created after EKS so the OIDC provider ARN is available
# ---------------------------------------------------------------------------

resource "aws_iam_role" "app_irsa" {
  name = "${var.project_name}-${var.environment}-app-irsa-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = module.eks.oidc_provider_arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${module.eks.oidc_provider_url}:sub" = "system:serviceaccount:max-weather:max-weather-sa"
          "${module.eks.oidc_provider_url}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  depends_on = [module.eks]
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

# ---------------------------------------------------------------------------
# EKS — Kubernetes cluster
# ---------------------------------------------------------------------------

module "eks" {
  source = "./modules/eks"

  project_name        = var.project_name
  environment         = var.environment
  kubernetes_version  = var.kubernetes_version
  vpc_id              = module.vpc.vpc_id
  private_subnet_ids  = module.vpc.private_subnet_ids
  public_subnet_ids   = module.vpc.public_subnet_ids
  eks_cluster_role_arn = module.iam.eks_cluster_role_arn
  eks_node_role_arn    = module.iam.eks_node_role_arn
  node_instance_type  = var.node_instance_type
  node_min_size       = var.node_min_size
  node_max_size       = var.node_max_size
  node_desired_size   = var.node_desired_size

  depends_on = [module.iam, module.vpc]
}

# ---------------------------------------------------------------------------
# ECR — container registry
# ---------------------------------------------------------------------------

module "ecr" {
  source = "./modules/ecr"

  project_name          = var.project_name
  environment           = var.environment
  image_retention_count = var.ecr_image_retention_count
}

# ---------------------------------------------------------------------------
# CloudWatch — logging and alarms
# ---------------------------------------------------------------------------

module "cloudwatch" {
  source = "./modules/cloudwatch"

  project_name          = var.project_name
  environment           = var.environment
  log_retention_days    = var.log_retention_days
  error_alarm_threshold = var.error_alarm_threshold
}

# ---------------------------------------------------------------------------
# Cluster add-ons — ArgoCD (GitOps) + Jenkins (CI/CD)
# ---------------------------------------------------------------------------

module "addons" {
  source = "./modules/addons"

  aws_region            = var.aws_region
  cluster_name          = module.eks.cluster_name
  github_repo_url       = var.github_repo_url
  github_username       = var.github_username
  github_pat            = var.github_pat
  aws_access_key_id     = var.aws_access_key_id
  aws_secret_access_key = var.aws_secret_access_key
  jenkins_irsa_role_arn = module.eks.jenkins_irsa_role_arn
  jwt_secret_arn        = var.jwt_secret_arn

  depends_on = [module.eks]
}

# ---------------------------------------------------------------------------
# Lambda Authorizer — JWT validation for API Gateway
# ---------------------------------------------------------------------------

module "lambda_authorizer" {
  source = "./modules/lambda_authorizer"

  project_name    = var.project_name
  environment     = var.environment
  jwt_secret_arn  = var.jwt_secret_arn
  lambda_role_arn = module.iam.lambda_authorizer_role_arn

  depends_on = [module.iam]
}
