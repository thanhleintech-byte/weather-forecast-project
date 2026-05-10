variable "aws_region" {
  type    = string
  default = "ap-south-1"
}

variable "project_name" {
  type    = string
  default = "max-weather"
}

variable "environment" {
  type    = string
  default = "production"
}

variable "argocd_hostname" {
  description = "Public hostname for the Argo CD UI. Empty = no ingress (port-forward only)."
  type        = string
  default     = ""
}

# ---------------------------------------------------------------------------
# GitOps source
# ---------------------------------------------------------------------------

variable "github_repo_url" {
  description = "HTTPS URL of the GitHub repository Argo CD watches"
  type        = string
}

variable "github_username" {
  type = string
}

variable "github_pat" {
  description = "GitHub Personal Access Token — readable by Argo CD and Jenkins for clone access"
  type        = string
  sensitive   = true
}

# ---------------------------------------------------------------------------
# Admin credentials — set explicitly instead of letting the helm charts
# random-generate, so they're reproducible across applies.
# ---------------------------------------------------------------------------

variable "argocd_admin_password" {
  description = "Plaintext Argo CD admin password — terraform bcrypt-hashes it before passing to the helm release"
  type        = string
  sensitive   = true
}

variable "jenkins_admin_password" {
  description = "Plaintext Jenkins admin password — written to a Kubernetes Secret referenced by the Jenkins helm chart's controller.admin.existingSecret"
  type        = string
  sensitive   = true
}

# ---------------------------------------------------------------------------
# Application secrets — mounted into the FastAPI pod
# ---------------------------------------------------------------------------

variable "jwt_secret_value" {
  description = "Same JWT signing key terraform put in Secrets Manager (used by the FastAPI pod)"
  type        = string
  sensitive   = true
}

variable "oauth_client_id" {
  description = "OAuth2 client_id accepted by the FastAPI /token endpoint"
  type        = string
}

variable "oauth_client_secret" {
  description = "OAuth2 client_secret accepted by the FastAPI /token endpoint"
  type        = string
  sensitive   = true
}
