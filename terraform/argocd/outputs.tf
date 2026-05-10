output "argocd_namespace" {
  value = helm_release.argocd.namespace
}

output "argocd_admin_login_hint" {
  description = "How to log in to Argo CD"
  value       = "kubectl -n argocd port-forward svc/argocd-server 8080:443  # then login as 'admin' with the plaintext password from credentials.local.env"
}

output "jenkins_admin_login_hint" {
  value = "kubectl -n jenkins port-forward svc/jenkins 8080:8080  # then login as 'admin' with JENKINS_ADMIN_PASSWORD"
}
