# Max Weather — Manual Deployment Runbook

Deploy from scratch by running terraform stages in order. Each stage is a
small terraform apply you can re-run independently. Copy commands top-to-bottom.

```
terraform/
  network/         ← VPC, NAT, subnets               (~3 min)
  eks/             ← EKS + IAM + ECR + CloudWatch    (~15 min)
  argocd/          ← Argo CD + k8s Secrets + apps    (~5 min)
  api-gateway/     ← Lambda authorizer + API Gateway (~1 min)
  modules/         ← reusable, called from stages
```

---

## 0. Prerequisites

```bash
aws --version          # >= 2.x
terraform -version     # >= 1.6
kubectl version --client
helm version
docker --version
node --version         # >= 20  (terraform runs `npm ci` in lambda/authorizer)
jq --version
```

Verify AWS auth and pick the account you intend to deploy into:

```bash
aws sts get-caller-identity
```

---

## 1. Configure secrets (one file, gitignored)

```bash
cd /path/to/max-weather

cp credentials.local.env.example credentials.local.env
# edit credentials.local.env — fill in real values for every TF_VAR_* line
$EDITOR credentials.local.env

source credentials.local.env
```

What's in there: GitHub PAT, JWT signing key, OAuth client_id/secret, Argo CD
admin password, Jenkins admin password, Cloudflare token, region. AWS access
keys are **not** required — Jenkins authenticates to AWS via IRSA, and your
local `aws` CLI uses your existing profile.

Sanity-check the env exported correctly:

```bash
echo "$TF_VAR_github_pat" | head -c 10        # should print first 10 chars of your PAT
echo "$TF_VAR_jwt_secret_value" | head -c 10
echo "$AWS_REGION"                            # ap-south-1 (or your override)
```

---

## 2. Stage 1 — `network`

Creates VPC, public + private subnets across 2 AZs, NAT gateways, route tables.

```bash
cd terraform/network
cp terraform.tfvars.example terraform.tfvars   # edit if you need overrides

terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

Expected outputs:
```
vpc_id              = "vpc-xxxxxxxx"
private_subnet_ids  = [...]
public_subnet_ids   = [...]
```

---

## 3. Stage 2 — `eks`

Creates the EKS cluster + node group, IAM roles (cluster, nodes, Lambda
authorizer, Jenkins IRSA, app IRSA), ECR repo, CloudWatch log groups + alarms.
Slowest stage.

```bash
cd ../eks
cp terraform.tfvars.example terraform.tfvars

terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

Capture the kubeconfig command from outputs and run it:

```bash
$(terraform output -raw kubeconfig_command)
kubectl get nodes      # all 3 should be Ready within ~2 min
```

---

## 4. Stage 3 — `argocd`

Installs Argo CD via Helm with a known admin password, creates the three
Kubernetes Secrets (`jenkins-credentials`, `jenkins-admin-secret`,
`max-weather-secrets`), then applies the Argo CD bootstrap so it begins
managing ingress-nginx, Jenkins, and the max-weather app.

```bash
cd ../argocd
cp terraform.tfvars.example terraform.tfvars

terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

Watch Argo CD reconcile. `ingress-nginx` and `metrics-server` come up first;
`jenkins` and `max-weather-prod` follow:

```bash
kubectl get applications -n argocd -w
# Ctrl-C once everything is Synced + Healthy
```

Get the public LB hostname for the Nginx ingress:

```bash
kubectl get svc -n ingress-nginx ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
# e.g. xxxxx.elb.ap-south-1.amazonaws.com
```

**Point DNS** at it. Set a CNAME from `$TF_VAR_app_host` (e.g. `max-weather.example.com`)
to the LB hostname. Wait until DNS resolves:

```bash
dig +short "$TF_VAR_app_host"
```

---

## 5. Build & push the app image to ECR

Argo CD has already deployed the Helm chart pointing at `:latest`, but the
image doesn't exist yet — pods will be in `ImagePullBackOff` until you push.

```bash
cd ../../app

ECR_URL=$(cd ../terraform/eks && terraform output -raw ecr_repository_url)

aws ecr get-login-password --region "$AWS_REGION" \
  | docker login --username AWS --password-stdin "$ECR_URL"

# Apple Silicon: add --platform=linux/amd64
docker build -t max-weather:1.0.0 .
docker tag max-weather:1.0.0 "$ECR_URL:1.0.0"
docker tag max-weather:1.0.0 "$ECR_URL:latest"
docker push "$ECR_URL:1.0.0"
docker push "$ECR_URL:latest"
```

Force a roll so pods pick up the new image:

```bash
kubectl -n max-weather rollout restart deployment/max-weather
kubectl -n max-weather rollout status deployment/max-weather
```

Verify the pod is up and reachable through the ingress:

```bash
kubectl -n max-weather get pods
curl -s "https://$TF_VAR_app_host/health"
# expect {"status":"ok","timestamp":"..."}
```

If `/health` 404s, see Troubleshooting below.

---

## 6. Stage 4 — `api-gateway`

Writes the JWT signing key into AWS Secrets Manager, builds the Lambda
authorizer (terraform runs `npm ci --omit=dev` automatically), and creates
the API Gateway with an HTTP_PROXY integration to `$TF_VAR_app_host`.

```bash
cd ../terraform/api-gateway
cp terraform.tfvars.example terraform.tfvars
# edit app_host in terraform.tfvars OR rely on TF_VAR_app_host (already exported)

terraform init
terraform plan -out=tfplan
terraform apply tfplan

terraform output api_gateway_url
```

---

## 7. End-to-end test

```bash
BASE=$(cd ../api-gateway && terraform output -raw api_gateway_url)

# Public — no auth
curl -s "$BASE/health" | jq

# Mint a JWT
TOKEN=$(curl -s -X POST "$BASE/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "username=$TF_VAR_oauth_client_id&password=$TF_VAR_oauth_client_secret&grant_type=password" \
  | jq -r .access_token)
echo "$TOKEN"

# Protected calls
curl -s "$BASE/weather/current?city=Mumbai" \
  -H "Authorization: Bearer $TOKEN" | jq
curl -s "$BASE/weather/forecast?city=London&days=3" \
  -H "Authorization: Bearer $TOKEN" | jq
curl -s "$BASE/weather/coordinates?lat=19.07&lon=72.87&days=2" \
  -H "Authorization: Bearer $TOKEN" | jq

# Negative: bad token → 403 explicit deny
curl -i "$BASE/weather/current?city=Mumbai" \
  -H "Authorization: Bearer not-a-real-token"

# Negative: no auth → 401
curl -i "$BASE/weather/current?city=Mumbai"
```

---

## 8. Argo CD + Jenkins UI

```bash
# Argo CD — login as admin / $TF_VAR_argocd_admin_password
kubectl -n argocd port-forward svc/argocd-server 8080:443
# Open https://localhost:8080  (accept self-signed cert)

# Jenkins — login as admin / $TF_VAR_jenkins_admin_password
kubectl -n jenkins port-forward svc/jenkins 8081:8080
# Open http://localhost:8081
```

---

## Cleanup

Destroy in **reverse order** of apply:

```bash
cd terraform/api-gateway && terraform destroy -auto-approve
cd ../argocd            && terraform destroy -auto-approve
cd ../eks               && terraform destroy -auto-approve
cd ../network           && terraform destroy -auto-approve
```

If `argocd` destroy hangs, force-delete finalizers on the Argo CD apps first:
```bash
kubectl -n argocd get applications -o name \
  | xargs -I {} kubectl -n argocd patch {} --type=merge \
      -p '{"metadata":{"finalizers":[]}}'
```

Manual cleanup terraform doesn't touch:
- DNS records you created
- ECR images (the repo is destroyed, but force-delete must be enabled)

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `terraform apply` in `eks` fails reading `network` outputs | `network` stage state missing or apply not yet finished | `cd ../network && terraform apply` first |
| `terraform plan` in `argocd` says "Failed to construct REST client" | kubeconfig stale | re-run `aws eks update-kubeconfig --region $AWS_REGION --name max-weather-production` |
| Argo CD apps stuck `OutOfSync` with "secret not found" | terraform secret resources didn't apply | check `kubectl get secrets -n jenkins`, `-n max-weather`; re-run `terraform apply` in argocd stage |
| `/weather/*` returns 500 `{"message": null}` | Lambda authorizer crash | `aws logs tail /aws/lambda/max-weather-authorizer-production --since 5m`. Usually missing `node_modules` — terraform module now runs `npm ci` so this should not recur |
| `/health` 404 from backend `$TF_VAR_app_host` | Ingress rewriting paths to `/` | confirm `gitops/argocd/microservices/max-weather/values.yaml` has **no** `nginx.ingress.kubernetes.io/rewrite-target: /` annotation |
| `/weather/*` returns 502/504 from API Gateway | DNS for `app_host` not resolving, or pod not ready | `dig +short $TF_VAR_app_host`, `kubectl -n max-weather get pods` |
| Bad token returns 200 instead of 403 | Authorizer cached previous Allow | wait 300s for the TTL or set `authorizer_result_ttl_in_seconds = 0` in `modules/api_gateway/main.tf` for testing |
| `bcrypt` causes argocd helm release to update on every apply | shouldn't happen — `terraform_data.argocd_admin_hash` caches the hash; if it does, change `TF_VAR_argocd_admin_password` once and re-apply to refresh |

---

## What changed vs. the old single-stage layout

- One root `terraform/` with everything → four stages (`network`, `eks`,
  `argocd`, `api-gateway`), each with its own state.
- `bootstrap.yaml` lived inside `modules/addons/` (a non-place to put a
  manifest that changes over time), then briefly at
  `terraform/argocd/bootstrap.yaml` → now lives at
  `gitops/argocd/bootstrap.yaml` and is itself a GitOps artifact.
  Terraform applies just that one root Application; every child
  Application is rendered by the Helm chart at `gitops/argocd/apps/`.
  Adding/removing a platform component is a pure GitOps change.
- `npm install` for the Lambda authorizer was a manual step (we hit
  `Cannot find module 'jsonwebtoken'` because of this) → terraform's
  `null_resource.npm_install` now runs it before `archive_file`.
- Static AWS access keys for Jenkins → IRSA only (Jenkins ServiceAccount
  has its IAM role attached). The `aws-credentials` JCasC entry was dead
  code and is removed.
- Argo CD admin password was auto-generated → set explicitly via
  `TF_VAR_argocd_admin_password`, bcrypt-hashed by terraform, cached so
  applies don't churn the helm release.
- Jenkins admin password was committed in `values.yaml` (`changeme123!`)
  → now read from `jenkins-admin-secret` via the chart's
  `controller.admin.existingSecret`.
- All secrets scattered across `terraform.tfvars` and source files →
  consolidated into `credentials.local.env` (gitignored), sourced as
  `TF_VAR_*` env vars by every stage.
