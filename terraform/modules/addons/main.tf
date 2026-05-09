locals {
  bootstrap_yaml = replace(
    file("${path.module}/bootstrap.yaml"),
    "GITHUB_REPO_URL",
    var.github_repo_url
  )
}

# ---------------------------------------------------------------------------
# ArgoCD — GitOps controller
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
}

# ---------------------------------------------------------------------------
# Jenkins credentials secret — created BEFORE ArgoCD installs Jenkins so
# JCasC can reference env vars on first boot.
# Secret keys use UPPER_SNAKE so envFrom mounts them as valid env var names.
# ---------------------------------------------------------------------------

resource "null_resource" "jenkins_credentials_secret" {
  triggers = {
    pat_hash = sha256(var.github_pat)
    key_hash = sha256(var.aws_access_key_id)
  }

  provisioner "local-exec" {
    command = <<-EOT
      aws eks update-kubeconfig \
        --region ${var.aws_region} \
        --name ${var.cluster_name} \
        --kubeconfig /tmp/max-weather-kubeconfig

      kubectl --kubeconfig /tmp/max-weather-kubeconfig \
        create namespace jenkins --dry-run=client -o yaml \
        | kubectl --kubeconfig /tmp/max-weather-kubeconfig apply -f -

      kubectl --kubeconfig /tmp/max-weather-kubeconfig \
        create secret generic jenkins-credentials \
          --namespace=jenkins \
          --from-literal=GITHUB_PAT='${var.github_pat}' \
          --from-literal=AWS_ACCESS_KEY_ID='${var.aws_access_key_id}' \
          --from-literal=AWS_SECRET_ACCESS_KEY='${var.aws_secret_access_key}' \
          --dry-run=client -o yaml \
        | kubectl --kubeconfig /tmp/max-weather-kubeconfig apply -f -
    EOT

    environment = {
      AWS_ACCESS_KEY_ID     = var.aws_access_key_id
      AWS_SECRET_ACCESS_KEY = var.aws_secret_access_key
      AWS_DEFAULT_REGION    = var.aws_region
    }
  }
}

# ---------------------------------------------------------------------------
# Bootstrap — apply all ArgoCD Application CRs after ArgoCD CRDs are ready.
# ArgoCD then takes over: installs ingress-nginx, jenkins, jenkins-pipelines,
# and the max-weather Helm chart from gitops/argocd/ in the GitHub repo.
# ---------------------------------------------------------------------------

resource "null_resource" "argocd_bootstrap" {
  triggers = {
    bootstrap_hash = sha256(local.bootstrap_yaml)
  }

  provisioner "local-exec" {
    command = <<-EOT
      aws eks update-kubeconfig \
        --region ${var.aws_region} \
        --name ${var.cluster_name} \
        --kubeconfig /tmp/max-weather-kubeconfig

      kubectl --kubeconfig /tmp/max-weather-kubeconfig apply -f - <<'BOOTSTRAP'
${local.bootstrap_yaml}
BOOTSTRAP
    EOT

    environment = {
      AWS_ACCESS_KEY_ID     = var.aws_access_key_id
      AWS_SECRET_ACCESS_KEY = var.aws_secret_access_key
      AWS_DEFAULT_REGION    = var.aws_region
    }
  }

  depends_on = [
    helm_release.argocd,
    null_resource.jenkins_credentials_secret,
  ]
}

# ---------------------------------------------------------------------------
# Add Jenkins IRSA role to aws-auth so kubectl works via IRSA inside the
# cluster without needing a kubeconfig file credential.
# ---------------------------------------------------------------------------

resource "null_resource" "jenkins_aws_auth" {
  triggers = {
    jenkins_role_arn = var.jenkins_irsa_role_arn
  }

  provisioner "local-exec" {
    command = <<-EOT
      aws eks update-kubeconfig \
        --region ${var.aws_region} \
        --name ${var.cluster_name} \
        --kubeconfig /tmp/max-weather-kubeconfig

      ROLE_ARN="${var.jenkins_irsa_role_arn}"

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

    environment = {
      AWS_ACCESS_KEY_ID     = var.aws_access_key_id
      AWS_SECRET_ACCESS_KEY = var.aws_secret_access_key
      AWS_DEFAULT_REGION    = var.aws_region
    }
  }

  depends_on = [null_resource.argocd_bootstrap]
}
