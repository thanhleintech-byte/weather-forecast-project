# ---------------------------------------------------------------------------
# Read EKS stage outputs — cluster endpoint, OIDC, etc.
# ---------------------------------------------------------------------------

data "terraform_remote_state" "eks" {
  backend = "local"
  config = {
    path = "../eks/terraform.tfstate"
  }
}

# ---------------------------------------------------------------------------
# Namespaces — pre-created so Secrets can land before the helm releases
# (Argo CD installs Jenkins / max-weather and they need the secrets present).
# ---------------------------------------------------------------------------

resource "kubernetes_namespace" "jenkins" {
  metadata { name = "jenkins" }
}

resource "kubernetes_namespace" "max_weather" {
  metadata { name = "max-weather" }
}

# ---------------------------------------------------------------------------
# Argo CD — installed via Helm. Admin password set explicitly via bcrypt
# hash; not random-generated. Plaintext lives in credentials.local.env.
# ---------------------------------------------------------------------------

resource "helm_release" "argocd" {
  name             = "argocd"
  namespace        = "argocd"
  create_namespace = true
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = "7.7.16"
  timeout          = 600
  wait             = true

  set {
    name  = "server.service.type"
    value = "ClusterIP"
  }
  set {
    name  = "configs.params.server\\.insecure"
    value = "true"
  }
  set {
    name  = "controller.resources.requests.memory"
    value = "256Mi"
  }
  set {
    name  = "controller.resources.requests.cpu"
    value = "100m"
  }

  # Public ingress for the Argo CD UI. argocd-server runs with --insecure
  # (HTTP), so the ingress can use plain HTTP backend; Cloudflare in front
  # terminates TLS for external clients.
  set {
    name  = "server.ingress.enabled"
    value = tostring(var.argocd_hostname != "")
    type  = "string"
  }
  set {
    name  = "server.ingress.ingressClassName"
    value = "nginx"
  }
  set {
    name  = "server.ingress.hostname"
    value = var.argocd_hostname
  }

  # Admin password — bcrypt of plaintext, but cached so we don't re-hash
  # (and trigger a helm re-install) on every plan. terraform_data only
  # re-computes when the plaintext changes.
  set_sensitive {
    name  = "configs.secret.argocdServerAdminPassword"
    value = terraform_data.argocd_admin_hash.output
  }
  set {
    name  = "configs.secret.argocdServerAdminPasswordMtime"
    value = "2024-01-01T00:00:00Z"
  }
}

resource "terraform_data" "argocd_admin_hash" {
  triggers_replace = { plaintext_hash = sha256(var.argocd_admin_password) }
  input            = bcrypt(var.argocd_admin_password, 10)
}

# ---------------------------------------------------------------------------
# Jenkins admin secret — referenced by jenkins helm chart's
# controller.admin.existingSecret. Replaces the committed `changeme123!`.
# ---------------------------------------------------------------------------

resource "kubernetes_secret" "jenkins_admin" {
  metadata {
    name      = "jenkins-admin-secret"
    namespace = kubernetes_namespace.jenkins.metadata[0].name
  }

  data = {
    "jenkins-admin-user"     = "admin"
    "jenkins-admin-password" = var.jenkins_admin_password
  }

  type = "Opaque"
}

# ---------------------------------------------------------------------------
# Jenkins credentials — GitHub PAT only. AWS access is via IRSA on the
# jenkins ServiceAccount, not static keys.
# ---------------------------------------------------------------------------

resource "kubernetes_secret" "jenkins_credentials" {
  metadata {
    name      = "jenkins-credentials"
    namespace = kubernetes_namespace.jenkins.metadata[0].name
  }

  data = {
    GITHUB_PAT      = var.github_pat
    GITHUB_USERNAME = var.github_username
  }

  type = "Opaque"
}

# ---------------------------------------------------------------------------
# max-weather app secret — JWT signing key + OAuth client creds. Mounted
# as env vars by the Helm chart's deployment template.
# ---------------------------------------------------------------------------

resource "kubernetes_secret" "max_weather" {
  metadata {
    name      = "max-weather-secrets"
    namespace = kubernetes_namespace.max_weather.metadata[0].name
  }

  data = {
    "jwt-secret"          = var.jwt_secret_value
    "oauth-client-id"     = var.oauth_client_id
    "oauth-client-secret" = var.oauth_client_secret
  }

  type = "Opaque"
}

# ---------------------------------------------------------------------------
# Bootstrap Argo CD — apply the gitops Application manifests so Argo CD
# starts managing ingress-nginx, jenkins, max-weather, etc.
#
# bootstrap.yaml is checked in NEXT TO this stage (not buried in a module)
# so it can be edited as apps are added/removed without touching modules.
# ---------------------------------------------------------------------------

locals {
  bootstrap_yaml = replace(
    file("${path.module}/bootstrap.yaml"),
    "GITHUB_REPO_URL",
    var.github_repo_url
  )
}

resource "null_resource" "argocd_bootstrap" {
  triggers = {
    bootstrap_hash = sha256(local.bootstrap_yaml)
  }

  provisioner "local-exec" {
    command = <<-EOT
      aws eks update-kubeconfig \
        --region ${var.aws_region} \
        --name ${data.terraform_remote_state.eks.outputs.cluster_name} \
        --kubeconfig /tmp/max-weather-kubeconfig

      kubectl --kubeconfig /tmp/max-weather-kubeconfig apply -f - <<'BOOTSTRAP'
${local.bootstrap_yaml}
BOOTSTRAP
    EOT
  }

  depends_on = [
    helm_release.argocd,
    kubernetes_secret.jenkins_credentials,
    kubernetes_secret.jenkins_admin,
    kubernetes_secret.max_weather,
  ]
}

# ---------------------------------------------------------------------------
# aws-auth — give the Jenkins IRSA role kubectl access in-cluster.
# ---------------------------------------------------------------------------

resource "null_resource" "jenkins_aws_auth" {
  triggers = {
    jenkins_role_arn = data.terraform_remote_state.eks.outputs.jenkins_irsa_role_arn
  }

  provisioner "local-exec" {
    command = <<-EOT
      aws eks update-kubeconfig \
        --region ${var.aws_region} \
        --name ${data.terraform_remote_state.eks.outputs.cluster_name} \
        --kubeconfig /tmp/max-weather-kubeconfig

      ROLE_ARN="${data.terraform_remote_state.eks.outputs.jenkins_irsa_role_arn}"

      if kubectl --kubeconfig /tmp/max-weather-kubeconfig \
          get configmap aws-auth -n kube-system \
          -o jsonpath='{.data.mapRoles}' | grep -q "$ROLE_ARN"; then
        echo "Jenkins role already in aws-auth — skipping"
      else
        CURRENT_ROLES=$(kubectl --kubeconfig /tmp/max-weather-kubeconfig \
          get configmap aws-auth -n kube-system \
          -o jsonpath='{.data.mapRoles}')
        NEW_ENTRY=$(printf -- "- rolearn: %s\n  username: jenkins\n  groups:\n  - system:masters\n" "$ROLE_ARN")
        MERGED="$${CURRENT_ROLES}$${NEW_ENTRY}"
        kubectl --kubeconfig /tmp/max-weather-kubeconfig \
          patch configmap aws-auth -n kube-system \
          --type=merge \
          -p "{\"data\":{\"mapRoles\":$(echo "$MERGED" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')}}"
        echo "Jenkins role added to aws-auth"
      fi
    EOT
  }

  depends_on = [helm_release.argocd]
}
