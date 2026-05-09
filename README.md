# Max Weather Platform

Production-ready weather forecasting API on AWS EKS — high availability, auto-scaling, OAuth2-secured, GitOps deployed.

**Stack:** Python FastAPI · AWS EKS (K8s 1.32) · API Gateway (REST) · Lambda Authorizer · ArgoCD · Jenkins · Terraform · CloudWatch

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                              AWS Cloud (ap-south-1 / Mumbai)                   │
│                                                                                 │
│  ┌─────────────────────┐                                                        │
│  │    Developer / CI   │                                                        │
│  │  (Jenkins Pipeline) │                                                        │
│  └──────────┬──────────┘                                                        │
│             │ docker push                                                        │
│             ▼                                                                   │
│  ┌─────────────────────┐                                                        │
│  │   Amazon ECR        │  (Container Registry)                                  │
│  │   max-weather       │                                                        │
│  └──────────┬──────────┘                                                        │
│             │ imagePull                                                          │
│             ▼                                                                   │
│                                                                                 │
│  Internet Traffic                                                               │
│       │                                                                         │
│       ▼                                                                         │
│  ┌────────────────────────────────────────┐                                     │
│  │          AWS API Gateway (REST API)    │                                     │
│  │  https://n1hr2duj11.execute-api.       │                                     │
│  │      ap-south-1.amazonaws.com/prod    │                                     │
│  └─────────────┬──────────────────────────┘                                     │
│                │ Authorization header present?                                   │
│                ▼                                                                 │
│  ┌─────────────────────────────────────┐                                        │
│  │     AWS Lambda Authorizer           │                                        │
│  │   (max-weather-authorizer)          │                                        │
│  │                                     │                                        │
│  │  1. Extract Bearer JWT              │◄──── AWS Secrets Manager               │
│  │  2. Verify HS256 signature          │      (JWT signing secret)              │
│  │  3. Check exp / iss / aud           │                                        │
│  │  4. Return Allow/Deny IAM policy    │                                        │
│  └───────────────┬─────────────────────┘                                        │
│                  │ Allow                                                         │
│                  ▼                                                               │
│  ┌─────────────────────────────────────────────────────────────────────────┐    │
│  │                    VPC  (10.0.0.0/16)                                   │    │
│  │                                                                         │    │
│  │  Public Subnets (10.0.1.0/24, 10.0.2.0/24)  — ap-south-1a, ap-south-1b │    │
│  │  ┌──────────────────────────────────────────────────────────────────┐   │    │
│  │  │  AWS Network Load Balancer  (created by Nginx Ingress Service)   │   │    │
│  │  └──────────────────────────┬───────────────────────────────────────┘   │    │
│  │                             │                                           │    │
│  │  Private Subnets (10.0.3.0/24, 10.0.4.0/24) — EKS Worker Nodes         │    │
│  │  ┌──────────────────────────▼───────────────────────────────────────┐  │    │
│  │  │                EKS Cluster  (K8s 1.32)                           │  │    │
│  │  │                                                                  │  │    │
│  │  │  ┌────────────────────────────────────────────────────────────┐  │  │    │
│  │  │  │  namespace: ingress-nginx                                  │  │  │    │
│  │  │  │  Nginx Ingress Controller (Deployment)                     │  │  │    │
│  │  │  └───────────────────────────┬────────────────────────────────┘  │  │    │
│  │  │                              │ routes /weather /token /health     │  │    │
│  │  │  ┌───────────────────────────▼────────────────────────────────┐  │  │    │
│  │  │  │  namespace: max-weather                                    │  │  │    │
│  │  │  │                                                            │  │  │    │
│  │  │  │  Service (ClusterIP :80)                                   │  │  │    │
│  │  │  │       │                                                    │  │  │    │
│  │  │  │       ▼                                                    │  │  │    │
│  │  │  │  Deployment: max-weather (2–10 replicas via HPA)           │  │  │    │
│  │  │  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐        │  │  │    │
│  │  │  │  │   Pod  AZ-a │  │   Pod  AZ-b │  │   Pod  ...  │        │  │  │    │
│  │  │  │  │  FastAPI    │  │  FastAPI    │  │  (auto-      │        │  │  │    │
│  │  │  │  │  :8000      │  │  :8000      │  │   scaled)    │        │  │  │    │
│  │  │  │  └──────┬──────┘  └──────┬──────┘  └─────────────┘        │  │  │    │
│  │  │  │         └────────────────┘                                 │  │  │    │
│  │  │  │                  │ HTTPS outbound (via NAT GW)             │  │  │    │
│  │  │  └──────────────────┼────────────────────────────────────────┘  │  │    │
│  │  │                     ▼                                            │  │    │
│  │  │  ┌──────────────────────────────────────────────────────────┐   │  │    │
│  │  │  │  HPA (autoscaling/v2)                                    │   │  │    │
│  │  │  │  minReplicas=2  maxReplicas=10  CPU target=70%           │   │  │    │
│  │  │  └──────────────────────────────────────────────────────────┘   │  │    │
│  │  │                                                                  │  │    │
│  │  │  ┌──────────────────────────────────────────────────────────┐   │  │    │
│  │  │  │  Fluent Bit DaemonSet                                    │   │  │    │
│  │  │  │  Collects stdout logs → CloudWatch Log Groups            │   │  │    │
│  │  │  └───────────────────────────┬──────────────────────────────┘   │  │    │
│  │  └──────────────────────────────┼───────────────────────────────── ┘  │    │
│  └─────────────────────────────────┼────────────────────────────────────┘    │
│                                    │                                           │
│  ┌─────────────────────────────────▼───────────────────────┐                  │
│  │  Amazon CloudWatch                                       │                  │
│  │  Log Groups:                                             │                  │
│  │    /eks/max-weather/application  (app stdout)            │                  │
│  │    /eks/max-weather/nginx        (ingress access logs)   │                  │
│  │    /aws/lambda/max-weather-authorizer                    │                  │
│  │  Metric Filters + Alarms (error rate, auth rejections)   │                  │
│  └─────────────────────────────────────────────────────────┘                  │
│                                                                                 │
└─────────────────────────────────────────────────────────────────────────────────┘

External:
  Pods  ──► https://api.open-meteo.com  (weather data, free, no API key)
  Pods  ──► https://geocoding-api.open-meteo.com  (city → lat/lon)
```

### Component Descriptions

| Component | Details |
|---|---|
| **API Gateway (REST)** | Public entry point. `GET /health` and `POST /token` are open; `ANY /weather/{proxy+}` requires a valid JWT. Lambda TOKEN Authorizer with 300 s cache TTL. |
| **Lambda Authorizer** | Node.js 20.x. Extracts Bearer token, fetches HS256 secret from Secrets Manager (cached on cold start), verifies `exp`/`iss`/`aud`, returns IAM Allow/Deny policy. |
| **VPC** | Multi-AZ. 2 public subnets (NLB, NAT GWs) + 2 private subnets (EKS nodes). One NAT GW per AZ to eliminate cross-AZ egress costs. |
| **EKS Cluster** | Managed control plane. Worker nodes: `t3.medium`, min 2 / desired 3 / max 10. Add-ons: CoreDNS, kube-proxy, VPC-CNI, EBS CSI. IRSA via OIDC provider. |
| **Nginx Ingress** | NLB → Nginx Ingress Controller → ClusterIP Service. Rate limit: 50 rps per client. JSON access logs to CloudWatch. |
| **HPA** | `autoscaling/v2`. CPU 70% and memory 80% targets. Scale-up: +2 pods/60 s. Scale-down: −1 pod/60 s, 300 s stabilisation window. |
| **Fluent Bit** | DaemonSet. Forwards JSON-structured pod stdout to `/eks/max-weather/application`. |
| **ECR** | Private registry. Scan on push, AES-256 encryption, lifecycle policy: keep 10 tagged / expire untagged after 7 days. |

### High Availability

| Mechanism | Configuration |
|---|---|
| Multi-AZ pod spread | `topologySpreadConstraints` with `maxSkew: 1` |
| Zero-downtime deploys | Rolling update `maxUnavailable=1, maxSurge=1` |
| Node drain protection | `PodDisruptionBudget` `minAvailable=1` |
| Traffic routing | `readinessProbe` gates pod inclusion in Service endpoints |
| Horizontal scaling | HPA handles morning traffic peaks, scales down overnight |

### Security Posture

| Control | Implementation |
|---|---|
| API authentication | JWT HS256, validated by Lambda Authorizer |
| Secret storage | AWS Secrets Manager (JWT key); Kubernetes Secrets for pod env vars |
| Network isolation | EKS nodes in private subnets, no public IPs |
| Container security | Non-root user, read-only filesystem, dropped capabilities |
| Image scanning | ECR scan on push |
| Rate limiting | Nginx Ingress `limit-rps: 50` per client |
| Audit logging | CloudWatch captures all Lambda Authorizer invocations |

---

## Project Structure

```
max-weather/
├── app/                                    # FastAPI application + tests
│   ├── main.py
│   ├── requirements.txt
│   ├── Dockerfile
│   └── tests/test_main.py
├── terraform/                              # Infrastructure as Code
│   ├── main.tf / variables.tf / outputs.tf / versions.tf
│   ├── terraform.tfvars.example
│   └── modules/
│       ├── vpc/                            # VPC, subnets, IGW, NAT GWs
│       ├── eks/                            # EKS cluster + node group
│       ├── ecr/                            # Container registry
│       ├── iam/                            # Roles: EKS, Lambda, IRSA
│       ├── cloudwatch/                     # Log groups, metric filters, alarms
│       ├── lambda_authorizer/              # JWT validation Lambda
│       ├── api_gateway/                    # REST API + TOKEN authorizer + routes
│       └── addons/                         # ArgoCD + Jenkins via Helm
├── gitops/argocd/
│   ├── bootstrap.yaml                      # ArgoCD root app-of-apps
│   ├── infra/                              # ingress-nginx, jenkins, metrics-server
│   └── microservices/max-weather/          # Helm chart (deployment, service, ingress, HPA, PDB)
├── lambda/authorizer/                      # Node.js 20.x JWT authorizer
│   ├── index.js
│   └── package.json
├── gitops/jenkins/Jenkinsfile              # CI/CD pipeline
└── postman/
    └── max-weather-api.postman_collection.json
```

---

## Prerequisites

| Tool | Version |
|------|---------|
| Terraform | >= 1.6.0 |
| AWS CLI | 2.x |
| kubectl | 1.32.x |
| Docker | 24.x |
| Node.js | 20.x |

AWS credentials must have permissions for: `EKS`, `EC2`, `IAM`, `ECR`, `Lambda`, `APIGateway`, `CloudWatch`, `SecretsManager`.

---

## Provisioning Guide

### Step 1 — Create the JWT Secret

Run once before the first `terraform apply`. The ARN is required as a Terraform input.

```bash
aws secretsmanager create-secret \
  --name "max-weather/jwt-secret" \
  --secret-string "$(openssl rand -base64 32)" \
  --region ap-south-1
```

Note the returned `ARN`.

### Step 2 — Configure Terraform Variables

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars` and set at minimum:

| Variable | Description |
|----------|-------------|
| `aws_region` | Target region (e.g. `ap-south-1`) |
| `environment` | `production` or `staging` |
| `jwt_secret_arn` | ARN from Step 1 |
| `github_repo_url` | HTTPS URL of this repo (used by ArgoCD + Jenkins) |
| `github_pat` | GitHub PAT with `repo` scope |
| `aws_access_key_id` | AWS key used by Jenkins for ECR push and EKS deploy |
| `aws_secret_access_key` | Corresponding secret key |

### Step 3 — Provision All Infrastructure (Terraform)

```bash
terraform init
terraform plan     # review before applying
terraform apply
```

Typical apply time: **20–25 minutes** (EKS control plane ~8 min, node group ~3 min).

Terraform provisions in dependency order:
1. **VPC** — multi-AZ (2 public + 2 private subnets, dual NAT GWs)
2. **IAM** — EKS cluster/node roles, Lambda role, IRSA role
3. **ECR** — container registry with lifecycle policy
4. **EKS** — cluster (K8s 1.32), managed node group (t3.medium, 2–10 nodes), add-ons
5. **CloudWatch** — log groups, metric filters, alarms
6. **Lambda Authorizer** — deploys `lambda/authorizer/` as a zip to Lambda
7. **API Gateway** — REST API with TOKEN authorizer, routes, and `prod` stage
8. **Addons** — installs ArgoCD and Jenkins via Helm; applies ArgoCD bootstrap manifest

After apply, retrieve all outputs:

```bash
terraform output
```

Key outputs:

| Output | Description |
|--------|-------------|
| `eks_cluster_name` | EKS cluster name |
| `ecr_repository_url` | ECR registry URL for Docker push |
| `api_gateway_url` | Public API Gateway invoke URL |
| `lambda_authorizer_arn` | Lambda authorizer ARN |
| `eks_kubeconfig_command` | Command to configure kubectl |

### Step 4 — Configure kubectl

```bash
aws eks update-kubeconfig --region ap-south-1 --name max-weather-production
kubectl get nodes    # should show nodes in Ready state
```

### Step 5 — Build and Push the Docker Image

```bash
ECR_URL=$(terraform output -raw ecr_repository_url)

aws ecr get-login-password --region ap-south-1 \
  | docker login --username AWS --password-stdin $ECR_URL

docker build -t max-weather ./app
docker tag  max-weather:latest $ECR_URL:latest
docker push $ECR_URL:latest
```

---

## GitOps — ArgoCD

Terraform installs ArgoCD via Helm and applies `gitops/argocd/bootstrap.yaml` (app-of-apps pattern).

ArgoCD then continuously syncs all applications from the Git repo:

| ArgoCD App | Source path | Namespace |
|---|---|---|
| `metrics-server` | `gitops/argocd/infra/metrics-server` | `kube-system` |
| `ingress-nginx` | `gitops/argocd/infra/ingress-nginx` | `ingress-nginx` |
| `jenkins` | `gitops/argocd/infra/jenkins` | `jenkins` |
| `jenkins-pipelines` | `gitops/argocd/infra/jenkins-pipelines` | `jenkins` |
| `max-weather` | `gitops/argocd/microservices/max-weather` | `max-weather` |

Any change merged to `main` in the GitOps paths above is automatically reconciled to the cluster. The `max-weather` Helm chart manages: Deployment, Service, Ingress, HPA (2–10 replicas), PDB, and ServiceAccount (with IRSA annotation for CloudWatch).

---

## CI/CD — Jenkins Pipeline

Jenkins is deployed into EKS by ArgoCD. The pipeline in `gitops/jenkins/Jenkinsfile` runs on every push to `main`:

```
Checkout ──► Test (pytest) ──► Build & Push (Kaniko → ECR) ──► Deploy to Production (kubectl rollout)
```

**Pipeline details:**

| Stage | Tool | Action |
|---|---|---|
| Checkout | git | Clone repo, extract short commit SHA |
| Test | python:3.12 container | `pytest` — publishes JUnit results |
| Build & Push | Kaniko (in-cluster) | Builds from `app/Dockerfile`, tags with build number + `latest`, pushes to ECR |
| Deploy to Production | aws-kubectl container | `kubectl set image` + `rollout status --timeout=180s` |

Jenkins pods run inside EKS using IRSA — no long-lived AWS keys in the cluster. ECR credentials are injected via a credential store.

---

## API Gateway + Lambda Authorizer

### Route Map

| Method | Path | Auth | Backend |
|--------|------|------|---------|
| `GET` | `/health` | None | `https://max-weather.workaholic.dpdns.org/health` |
| `POST` | `/token` | None | `https://max-weather.workaholic.dpdns.org/token` |
| `ANY` | `/weather/{proxy+}` | JWT required | `https://max-weather.workaholic.dpdns.org/weather/{proxy}` |

**Base URL:** `https://n1hr2duj11.execute-api.ap-south-1.amazonaws.com/prod`

### OAuth2 Flow

```
Client ──POST /token (client_id + client_secret)──► FastAPI
                                                        │
                                              Returns signed JWT (HS256, 60 min)
                                                        │
Client ──GET /weather/...  Authorization: Bearer <jwt>──► API Gateway
                                                              │
                                                     Lambda TOKEN Authorizer
                                                     (fetches secret from Secrets Manager,
                                                      verifies sig + exp + iss + aud,
                                                      returns Allow/Deny IAM policy, TTL 300s)
                                                              │ Allow
                                                          FastAPI pod
```

### Lambda Authorizer

- **Runtime:** Node.js 20.x
- **Source:** `lambda/authorizer/index.js`
- **Secret:** fetched from AWS Secrets Manager on cold start, cached in-memory
- **Validates:** HS256 signature, `exp`, `iss=max-weather`, `aud=max-weather-api`
- **Returns:** IAM policy (`execute-api:Invoke` Allow or Deny)

---

## Testing with Postman

1. Import `postman/max-weather-api.postman_collection.json`
2. Set collection variable `base_url` = `https://n1hr2duj11.execute-api.ap-south-1.amazonaws.com/prod`
3. Run **Get Access Token** (`POST /token`) — test script auto-saves the JWT to `access_token`
4. Run the `/weather/*` requests — they send `Authorization: Bearer {{access_token}}` automatically
5. Run **Unauthorized Request** — expect 401/403

Default credentials: `client_id` = `max-weather-client`, `client_secret` = `super-secret-key`

---

## Secrets & External Configuration

Everything below lives **outside the codebase** and must exist before or alongside provisioning. None of these values are committed to Git.

---

### 1. AWS Secrets Manager — JWT Signing Key

Created manually in Step 1 of provisioning. Referenced by ARN in `terraform.tfvars`.

| Secret name | Value | Used by |
|---|---|---|
| `max-weather/jwt-secret` | Base64-encoded random 32-byte key | Lambda Authorizer (validates tokens), FastAPI app (signs tokens) |

The Lambda Authorizer fetches this on cold start and caches it in-memory. The FastAPI pod receives it via the `max-weather-secrets` Kubernetes Secret (see below).

---

### 2. `terraform.tfvars` — Sensitive Inputs

These values are never committed. Copy `terraform.tfvars.example` and populate:

| Variable | Where to get it | Sensitive |
|---|---|---|
| `jwt_secret_arn` | Output of Step 1 `create-secret` command | No (ARN only) |
| `github_pat` | GitHub → Settings → Developer settings → Personal access tokens (scope: `repo`) | **Yes** |
| `aws_access_key_id` | IAM user with ECR push + EKS deploy permissions | **Yes** |
| `aws_secret_access_key` | Paired with above | **Yes** |

---

### 3. Kubernetes Secret: `jenkins-credentials` (namespace: `jenkins`)

Created automatically by `terraform apply` (addons module `local-exec`) **before** ArgoCD installs Jenkins, so Jenkins Configuration-as-Code (JCasC) can reference the values on first boot.

| Key | Value source | Used by |
|---|---|---|
| `GITHUB_PAT` | `var.github_pat` from tfvars | JCasC → Jenkins credential `github-pat` |
| `AWS_ACCESS_KEY_ID` | `var.aws_access_key_id` from tfvars | JCasC → Jenkins credential `aws-credentials` |
| `AWS_SECRET_ACCESS_KEY` | `var.aws_secret_access_key` from tfvars | JCasC → Jenkins credential `aws-credentials` |

Jenkins mounts this secret via `envFrom` and JCasC expands `${GITHUB_PAT}` etc. at startup.

To rotate: update `terraform.tfvars` and re-run `terraform apply` (the `local-exec` trigger is keyed on a hash of the values).

---

### 4. Jenkins Credentials Store (auto-populated by JCasC)

These are created inside Jenkins on first boot from the `jenkins-credentials` secret above. No manual Jenkins UI steps required.

| Credential ID | Type | Value |
|---|---|---|
| `github-pat` | Username/Password | Username: `thanhleintech-byte`, Password: `${GITHUB_PAT}` |
| `aws-credentials` | Username/Password | Username: `${AWS_ACCESS_KEY_ID}`, Password: `${AWS_SECRET_ACCESS_KEY}` |
| `aws-region` | Secret string | `ap-south-1` |
| `ecr-registry-url` | Secret string | `047750375423.dkr.ecr.ap-south-1.amazonaws.com` |

The Jenkinsfile references `ecr-registry-url` via `credentials('ecr-registry-url')`.

---

### 5. Jenkins Admin Password

Defined in `gitops/argocd/infra/jenkins/values.yaml`:

| Username | Default password | Action required |
|---|---|---|
| `admin` | `changeme123!` | **Change immediately after first login** at `https://jenkins.workaholic.dpdns.org` |

---

### 6. ArgoCD Admin Password

ArgoCD sets the initial admin password to the name of its server pod on first install. Retrieve it:

```bash
kubectl get secret argocd-initial-admin-secret \
  -n argocd \
  -o jsonpath='{.data.password}' | base64 -d
```

Access the UI via port-forward (no Ingress configured for ArgoCD):

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
# then open https://localhost:8080  (username: admin)
```

Change the password after first login via the ArgoCD UI or CLI.

---

### 7. Kubernetes Secret: `max-weather-secrets` (namespace: `max-weather`)

Created automatically by `terraform apply` (addons module). Fetches the JWT signing key from Secrets Manager and stores it as a K8s secret so pods never need direct AWS access for the secret value.

| Key | Value source | Mounted as |
|---|---|---|
| `jwt-secret` | Fetched from `max-weather/jwt-secret` in Secrets Manager | `JWT_SECRET` env var in FastAPI pods |

---

### 8. Application Demo Credentials

Hardcoded in `app/main.py` for the OAuth2 token endpoint. Change before any public-facing deployment.

| `client_id` | `client_secret` |
|---|---|
| `max-weather-client` | `super-secret-key` |

---

## CloudWatch Observability

| Log Group | Source |
|---|---|
| `/eks/max-weather/application` | App pods (JSON structured via Fluent Bit DaemonSet) |
| `/eks/max-weather/nginx` | Nginx Ingress access logs |
| `/aws/lambda/max-weather-authorizer` | Lambda authorizer invocations |

**Metric filters → Alarms:**
- `MaxWeatherErrorCount` — fires when ERROR log events exceed 10 per 5 min
- `MaxWeatherAuthRejections` — fires when auth rejections exceed 50 per 5 min (security signal)

---

## Terraform Modules

| Module | Resources Created |
|---|---|
| `vpc` | VPC, public/private subnets, IGW, NAT GWs, route tables |
| `eks` | EKS cluster, managed node group, OIDC provider, add-ons |
| `ecr` | ECR repository + lifecycle policy |
| `iam` | EKS roles, node role, IRSA role, Lambda role |
| `cloudwatch` | Log groups, metric filters, alarms |
| `lambda_authorizer` | Lambda function + API Gateway permission |
| `api_gateway` | REST API, Lambda TOKEN authorizer, routes, `prod` stage |
| `addons` | ArgoCD + Jenkins via Helm, bootstrap manifest, Jenkins credentials |

All modules accept `project_name` and `environment` — change `environment = "staging"` to spin up an identical staging stack.

---

## Deployed Resources (ap-south-1, account 047750375423)

| Resource | Value |
|----------|-------|
| VPC | `vpc-06a09cf8e730e309f` |
| EKS Cluster | `max-weather-production` (Kubernetes 1.32) |
| ECR | `047750375423.dkr.ecr.ap-south-1.amazonaws.com/max-weather` |
| API Gateway | `https://n1hr2duj11.execute-api.ap-south-1.amazonaws.com/prod` |
| Lambda Authorizer | `arn:aws:lambda:ap-south-1:047750375423:function:max-weather-authorizer-production` |
| IRSA Role | `arn:aws:iam::047750375423:role/max-weather-production-app-irsa-role` |
| JWT Secret | `arn:aws:secretsmanager:ap-south-1:047750375423:secret:max-weather/jwt-secret-VFpr5F` |
| CW Log Group (app) | `/eks/max-weather/application` |
| CW Log Group (nginx) | `/eks/max-weather/nginx` |

---

## Potential Enhancements

### API Gateway — VPC Link (PrivateLink)
Currently API Gateway reaches the backend via the **public internet**: it resolves `max-weather.workaholic.dpdns.org` to the NLB's public DNS and sends traffic over the open internet. The NLB is therefore internet-reachable, meaning a client who discovers the NLB hostname can bypass API Gateway and the Lambda Authorizer entirely.

Fix: replace the public NLB with an internal NLB and connect API Gateway via a VPC Link.

- Add `service.beta.kubernetes.io/aws-load-balancer-internal: "true"` to the Nginx Ingress service in `gitops/argocd/infra/ingress-nginx/values-prod.yaml`
- Add an `aws_api_gateway_vpc_link` resource to `terraform/modules/api_gateway/main.tf` pointing at the internal NLB ARN
- Change all three integrations from `connection_type = "INTERNET"` to `connection_type = "VPC_LINK"` with the VPC Link ID

Traffic path becomes: `API Gateway → AWS backbone → internal NLB → Nginx Ingress → pods` — NLB is no longer reachable from the internet.

---

### CI/CD — Staging Environment + Manual Approval Gate
The current Jenkinsfile deploys directly to production on every merge to `main`. The assignment intent (and production best practice) is:

```
Test → Build → Deploy Staging → Smoke Tests → Manual Approval → Deploy Production
```

Changes needed in `gitops/jenkins/Jenkinsfile`:
- Add a `Deploy to Staging` stage that targets a `max-weather-staging` namespace (or a separate EKS cluster)
- Add a smoke test stage (e.g. `curl` the staging API Gateway URL and assert HTTP 200)
- Add an `input` step (`Proceed to production?`) between staging and production deploy

The Terraform environment variable already supports `staging` — a second `terraform apply -var environment=staging` would provision an identical staging stack.

---

### ArgoCD — Ingress & TLS
ArgoCD is currently only accessible via `kubectl port-forward`. For team access, add an Ingress to expose the ArgoCD UI:

- Add an ArgoCD Ingress in `gitops/argocd/infra/` with the `nginx` ingress class and a cert-manager TLS annotation
- Alternatively add `server.ingress.enabled: true` to the ArgoCD Helm values

---

### Jenkins Admin Password — External Secret
The Jenkins admin password (`changeme123!`) is hardcoded in `gitops/argocd/infra/jenkins/values.yaml` (committed to Git). It should be moved to the `jenkins-credentials` Kubernetes Secret (managed by Terraform) and referenced via `admin.existingSecret` in the Helm values.

---

### JWT — Asymmetric Signing (RS256)
The current implementation uses HS256 with a shared secret. For a multi-service setup, RS256 is preferable: the app signs with a private key; any service can verify with the public key without ever seeing the private key. The Lambda Authorizer would fetch the public key (or JWKS endpoint) rather than the shared secret.

---

### CloudWatch — Dashboard
Log groups, metric filters, and alarms are provisioned but there is no CloudWatch Dashboard. Add an `aws_cloudwatch_dashboard` resource to `terraform/modules/cloudwatch/main.tf` to surface request rate, error rate, auth rejection rate, HPA replica count, and pod CPU/memory in a single view.

---

### Terraform — Automated Tests
The assignment notes that CloudWatch and scaling code "must be tested prior to submission." No `.tftest.hcl` (Terraform native tests) or Terratest files currently exist. Adding unit tests for the `cloudwatch` and `api_gateway` modules would validate resource configuration without a full `apply`.

---

### API Gateway — WAF & Throttling
API Gateway is currently open to the internet without rate limiting at the AWS layer (rate limiting is only enforced at the Nginx layer inside the cluster). Additions worth considering:

- Attach an AWS WAF Web ACL to the API Gateway stage for IP-based blocking and managed rule sets
- Configure per-stage throttling (`default_route_settings`) to cap burst and steady-state request rates
- Add API usage plans and API keys for client-level quota management

---

## Tear Down

```bash
cd terraform
terraform destroy

aws secretsmanager delete-secret \
  --secret-id max-weather/jwt-secret \
  --region ap-south-1 \
  --force-delete-without-recovery
```
