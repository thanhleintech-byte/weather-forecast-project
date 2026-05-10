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
│  │  │  │  Deployment: max-weather (3–10 replicas via HPA)           │  │  │    │
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
│  │  │  │  minReplicas=3  maxReplicas=10  CPU target=70%           │   │  │    │
│  │  │  └──────────────────────────────────────────────────────────┘   │  │    │
│  │  │                                                                  │  │    │
│  │  │  ┌──────────────────────────────────────────────────────────┐   │  │    │
│  │  │  │  Fluent Bit DaemonSet  (kube-system)                     │   │  │    │
│  │  │  │  Tails every pod's stdout → CloudWatch Logs              │   │  │    │
│  │  │  └───────────────────────────┬──────────────────────────────┘   │  │    │
│  │  └──────────────────────────────┼───────────────────────────────── ┘  │    │
│  └─────────────────────────────────┼────────────────────────────────────┘    │
│                                    │                                           │
│  ┌─────────────────────────────────▼───────────────────────┐                  │
│  │  Amazon CloudWatch                                       │                  │
│  │  Log Groups:                                             │                  │
│  │    /eks/max-weather/application  (every pod's stdout)    │                  │
│  │    /eks/max-weather/nginx        (reserved — see Logs)   │                  │
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
| **HPA** | `autoscaling/v2`. CPU 70% and memory 80% targets. Scale-up: +2 pods/60 s. Scale-down: −1 pod/60 s, 300 s stabilisation window. See *Scaling — Pod level (reactive)*. |
| **Cluster Autoscaler** | Deployed via ArgoCD into `kube-system`. Drives the EKS node group's ASG up/down based on pending pods. IRSA-authenticated, ASG discovery by tag. See *Scaling — Node level (reactive)*. |
| **Scheduled scaler** | Two `CronJob`s in the `max-weather` namespace that patch the HPA's `minReplicas` at fixed times (05:30 / 22:00 IST). See *Scaling — Pod level (scheduled)*. |
| **Fluent Bit** | `aws-for-fluent-bit` Helm chart, deployed by ArgoCD into `kube-system` as a DaemonSet on every node. Tails `/var/log/containers/*.log` and writes every pod's stdout to `/eks/max-weather/application` via the `cloudwatch_logs` output plugin. IRSA-authenticated; no static AWS keys. |
| **ECR** | Private registry. Scan on push, AES-256 encryption, lifecycle policy: keep 10 tagged / expire untagged after 7 days. |

### High Availability

The platform is HA at **two layers** — the worker nodes are spread across availability zones, and the application pods are forced to spread across those zones too. Either layer alone is insufficient: HA nodes don't help if every pod lands in one AZ, and HA pods don't help if every node is in one AZ.

#### Node level — across availability zones

| Mechanism | Where | Detail |
|---|---|---|
| Multi-AZ VPC | `terraform/modules/vpc/main.tf` | 2 public + 2 private subnets, each pair in a different AZ (`ap-south-1a`, `ap-south-1b`). |
| Node group spans both AZs | `terraform/modules/eks/main.tf` (`aws_eks_node_group.this.subnet_ids = var.private_subnet_ids`) | EKS-managed ASG balances capacity across the supplied subnets, so node loss in one AZ never takes the whole worker pool down. |
| One NAT GW per AZ | `terraform/modules/vpc/main.tf` (`single_nat_gateway = false` in prod) | Egress from a private subnet stays in-AZ. A NAT failure in one AZ doesn't break egress for pods in the other. |
| EKS control plane | AWS-managed | Multi-AZ by default — managed by AWS, not us. |

#### Pod level — scheduled across availability zones

| Mechanism | Where | Detail |
|---|---|---|
| Topology spread constraint | `gitops/argocd/microservices/max-weather/templates/deployment.yaml` | `topology.kubernetes.io/zone`, `maxSkew: 1`, `whenUnsatisfiable: DoNotSchedule`. Pods are scheduled so that at any time the per-zone count differs by at most one. `DoNotSchedule` is strict — the scheduler refuses to place a pod that would break the skew rather than degrading silently. |
| Pod Disruption Budget | `gitops/argocd/microservices/max-weather/templates/pdb.yaml` | `minAvailable: 1` (prod). Voluntary disruptions (node drain, autoscaler scale-down, rolling update) cannot evict pods if doing so would leave fewer than 1 available. |
| Rolling update strategy | `templates/deployment.yaml` | `maxUnavailable: 1, maxSurge: 1`. New pods come up before old ones go down. |
| Readiness gating | `templates/deployment.yaml` | The Service only routes to pods passing `readinessProbe`, so traffic never hits a pod that isn't ready. |

### Scaling

The morning forecast-check spike is handled by **layered scaling** along two axes — *what* scales (pods vs nodes) and *what triggers it* (live load vs the clock). Reactive scaling reacts to actual traffic; scheduled scaling pre-positions capacity before predictable peaks so cold-start latency doesn't show up in user-visible response times.

|  | Pod level | Node level |
|---|---|---|
| **Reactive** (load-driven) | HPA on CPU + memory | Cluster Autoscaler |
| **Scheduled** (clock-driven) | CronJobs patching the HPA's `minReplicas` | Cascades from scheduled pod scale-up — once HPA's floor rises, CA provisions nodes to fit the new pods |

#### Pod level — reactive (HPA)

`gitops/argocd/microservices/max-weather/templates/hpa.yaml`, enabled in `values-prod.yaml`:

| Setting | Value |
|---|---|
| API | `autoscaling/v2` |
| CPU target | 70% utilisation |
| Memory target | 80% utilisation |
| `minReplicas` / `maxReplicas` | 3 / 10 (floor moves at scheduled times — see below) — 3 satisfies HA across 2 AZs (`maxSkew: 1` ⇒ 2-1 spread, so any single pod loss still leaves both zones covered) |
| Scale-up policy | `+2 pods / 60s`, 60s stabilisation |
| Scale-down policy | `-1 pod / 60s`, 300s stabilisation |

The asymmetric stabilisation windows mean we add capacity quickly and shed it cautiously, which avoids flapping when traffic dips briefly mid-peak.

#### Node level — reactive (Cluster Autoscaler)

`gitops/argocd/infra/cluster-autoscaler/` (Helm wrapper around the upstream `kubernetes/autoscaler` chart, deployed to `kube-system` by ArgoCD).

| Mechanism | Detail |
|---|---|
| Discovery | The managed node group carries `k8s.io/cluster-autoscaler/<cluster>=owned` and `k8s.io/cluster-autoscaler/enabled=true` tags (set in `terraform/modules/eks/main.tf`). The autoscaler discovers the ASG by tag — no static cluster-name list to maintain. |
| AWS access | IRSA. `terraform/modules/eks/main.tf` creates the role `<cluster>-cluster-autoscaler-role` with a least-privilege policy: `Describe*` on EC2/ASG/EKS, plus `SetDesiredCapacity` / `TerminateInstanceInAutoScalingGroup` *only* on ASGs tagged for this cluster (the `aws:ResourceTag/k8s.io/cluster-autoscaler/<cluster> = owned` condition). |
| Scale-up trigger | Pending pods that can't fit on existing nodes (e.g. when HPA increases replica count past current node capacity). |
| Scale-down trigger | A node is under-utilised for `scale-down-unneeded-time` (5 min) AND its pods can be rescheduled elsewhere. `scale-down-delay-after-add: 5m` prevents thrashing immediately after a scale-up. |
| Bounds | The node group's `min_size` / `max_size` (2 / 10 in prod) — the autoscaler can't go below or above what Terraform set. `desired_size` is in `lifecycle.ignore_changes` so subsequent `terraform apply`s don't fight the autoscaler. |
| Expander | `least-waste` — when multiple node group choices could fit the pending pods, pick the one that leaves the smallest amount of unused CPU/memory. |

#### Pod level — scheduled (CronJobs)

`gitops/argocd/microservices/max-weather/templates/scheduled-scaler.yaml`, configured in `values-prod.yaml`:

| Schedule | Time (Asia/Kolkata) | New `minReplicas` |
|---|---|---|
| `morning-up` | 05:30 daily | 5 |
| `night-down` | 22:00 daily | 3 |

A `CronJob` runs a single `kubectl patch hpa max-weather --type=merge --patch '{"spec":{"minReplicas":N}}'`. It uses a dedicated ServiceAccount (`max-weather-scaler`) bound to a Role that allows only `get`/`patch` on the one named HPA — no broader cluster privileges.

The HPA continues reactive scaling between these schedules; the cron just shifts the lower bound. Concretely:
- 05:30 → cron sets `minReplicas=5`. HPA immediately scales pods up to 5 (or higher if load already demands more). If the cluster doesn't have room for the new pods, Cluster Autoscaler adds a node.
- During the day → if traffic exceeds what 5 pods can handle, HPA scales further (up to `maxReplicas=10`) and CA adds nodes to fit. If traffic stays below CPU/memory targets, HPA holds at 5.
- 22:00 → cron sets `minReplicas=3`. HPA scales down (subject to the 300s stabilisation window). After ~10 minutes of idle nodes, CA scales the ASG back down.

This is the "node-level scheduled scaling" requirement satisfied **indirectly** — there's no second cron that resizes the node group itself, because Cluster Autoscaler will follow the pod count automatically. Adding a direct ASG cron would be redundant and could fight the autoscaler.

> **Disabling for staging:** `scheduledScaling.enabled: false` is the default in `values.yaml`, so the staging install does not create the CronJobs or RBAC.

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
│   ├── bootstrap.yaml                      # Single root Application — only file terraform applies
│   ├── apps/                               # Helm chart producing the child Applications
│   ├── infra/                              # ingress-nginx, jenkins, metrics-server, cluster-autoscaler, fluent-bit
│   └── microservices/max-weather/          # Helm chart (deployment, service, ingress, HPA, PDB, scheduled-scaler)
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
8. **Addons** — installs **ArgoCD only** via Helm; pre-creates `jenkins-credentials` and `max-weather-secrets` K8s secrets; applies the ArgoCD bootstrap manifest; patches `aws-auth` for Jenkins IRSA. Everything else (Jenkins, Nginx, app) is then installed by ArgoCD from Git.

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

## Bootstrap Flow — Terraform → ArgoCD → GitOps

Terraform's responsibility ends at handing control to ArgoCD. From that point, all cluster state is driven from Git.

The bootstrap is structured as a strict **app-of-apps**: terraform applies exactly one ArgoCD `Application` (the "root"), and that root app installs a Helm chart whose only output is more `Application` CRs — one per platform component. Adding or removing a platform component is therefore a pure GitOps change: drop a template into `gitops/argocd/apps/templates/` and commit. No terraform change required.

```
gitops/argocd/
  bootstrap.yaml                ← root Application (terraform applies just this one file)
  apps/                         ← Helm chart that emits one child Application per component
    Chart.yaml
    values.yaml                 ← repoURL/revision get overridden by the root via helm.values
    templates/
      metrics-server.yaml
      ingress-nginx.yaml
      cluster-autoscaler.yaml
      jenkins.yaml
      jenkins-pipelines.yaml
      max-weather-prod.yaml
  infra/                        ← actual Helm charts each child Application points at
  microservices/max-weather/
```

```
terraform apply
      │
      ├─1─► helm install argocd                    (ArgoCD controller running in EKS)
      │
      ├─2─► kubectl create secret                  jenkins-credentials   (namespace: jenkins)
      │                                            jenkins-admin-secret  (namespace: jenkins)
      │                                            max-weather-secrets   (namespace: max-weather)
      │
      ├─3─► kubectl apply gitops/argocd/bootstrap.yaml
      │       (single root Application — terraform substitutes GITHUB_REPO_URL once
      │        and passes it through as a Helm value to the apps chart)
      │           │
      │           ▼
      │     ArgoCD reconciles the root Application
      │           │
      │           │  ArgoCD reads the Helm chart at gitops/argocd/apps/, which renders
      │           │  one Application per template. Each child Application uses the same
      │           │  repoURL (via {{ .Values.repoURL }}) so the URL lives in exactly one place.
      │           │
      │           ├──► metrics-server        → kube-system
      │           ├──► ingress-nginx         → ingress-nginx      (creates public NLB)
      │           ├──► cluster-autoscaler    → kube-system        (drives ASG scale-up/down)
      │           ├──► jenkins               → jenkins            (Helm, reads jenkins-credentials secret)
      │           ├──► jenkins-pipelines     → jenkins            (registers pipeline job via Job DSL)
      │           └──► max-weather-prod      → max-weather        (Deployment, Service, Ingress, HPA, PDB, scheduled scaler)
      │
      └─4─► patch aws-auth configmap               (Jenkins IRSA role → system:masters)
```

The repo URL flows through the chain in one direction:

```
terraform: var.github_repo_url
   │
   ▼ string substitution at apply time
gitops/argocd/bootstrap.yaml
   │  spec.source.repoURL: <url>
   │  spec.source.helm.values: { repoURL: <url>, revision: main }
   ▼
gitops/argocd/apps/templates/*.yaml
   │  source.repoURL: {{ .Values.repoURL }}
   ▼
infra/* and microservices/max-weather/* (the actual workloads)
```

Any subsequent change to a file under `gitops/argocd/` merged to `main` is automatically reconciled to the cluster by ArgoCD (`automated.selfHeal: true`, `automated.prune: true`). No manual `kubectl apply` is required after the initial bootstrap.

---

## CI/CD Flow — GitHub → Jenkins → ECR → EKS

Jenkins itself is a GitOps-managed workload (installed by ArgoCD). Once running, it handles application CI/CD triggered by GitHub.

**Trigger rules** (enforced by `when` directives in the Jenkinsfile):

| Branch | Path filter | Result |
|---|---|---|
| `main` | change touches `app/**` | Test → Build & Push → **Deploy to Production** (`max-weather` namespace) |
| `develop` | change touches `app/**` | Test → Build & Push → **Deploy to Staging** (`max-weather-staging` namespace) |
| any other branch | — | Pipeline runs but all stages no-op |
| any branch | change does **not** touch `app/**` | Pipeline runs but all stages no-op |

A manual Jenkins build (UI "Build Now") bypasses the path filter, so you can re-deploy without an `app/` commit.

```
Developer pushes to GitHub
      │
      │  GitHub webhook  (multibranch scan picks up main + develop)
      ▼
Jenkins (running in EKS, namespace: jenkins)
      │
      ├─ Stage: Checkout
      │         git clone repo
      │         extract short commit SHA
      │         compute floating tag:  main → latest    develop → staging
      │
      ├─ Stage: Test            (when: branch in {main, develop} AND app/** changed)
      │         container: python:3.12
      │         pytest app/tests/ → JUnit XML results
      │
      ├─ Stage: Build & Push    (when: branch in {main, develop} AND app/** changed)
      │         container: kaniko (in-cluster, no Docker socket needed)
      │         reads ECR URL from Jenkins credential store (ecr-registry-url)
      │         builds from app/Dockerfile
      │         pushes two tags to ECR (same repo for prod and staging):
      │           047750375423.dkr.ecr.ap-south-1.amazonaws.com/max-weather:<build-number>
      │           047750375423.dkr.ecr.ap-south-1.amazonaws.com/max-weather:<latest|staging>
      │
      ├─ Stage: Deploy to Production  (when: branch == main AND app/** changed)
      │         container: aws-kubectl
      │         aws eks update-kubeconfig  (uses Jenkins IRSA role — no static AWS keys)
      │         kubectl set image deployment/max-weather max-weather=<new-image> -n max-weather
      │         kubectl rollout status -n max-weather --timeout=180s
      │
      └─ Stage: Deploy to Staging     (when: branch == develop AND app/** changed)
                container: aws-kubectl
                kubectl set image deployment/max-weather max-weather=<new-image> -n max-weather-staging
                kubectl rollout status -n max-weather-staging --timeout=180s
                    │
                    ▼
                EKS performs rolling update in the target namespace
                (maxUnavailable=1, maxSurge=1)
                old pods terminated only after new pods pass readinessProbe
```

**Key design points:**

| Point | Detail |
|---|---|
| Same ECR for both environments | One ECR repo (`max-weather`). Each build pushes a unique build-number tag plus a branch-floating tag (`:latest` for prod, `:staging` for develop) so a develop build never overwrites prod's `:latest`. |
| Path-scoped triggering | All work stages are gated on `changeset 'app/**'`. Pure infra/docs commits trigger a no-op build. A `triggeredBy 'UserIdCause'` escape hatch lets a manual build run unconditionally. |
| Staging namespace prerequisite | The pipeline calls `kubectl set image` against an existing `Deployment/max-weather` in `max-weather-staging` — that deployment must already exist (see *Staging Setup* below) or the deploy step fails. |
| No static AWS keys in cluster | Jenkins uses IRSA (IAM role bound to K8s ServiceAccount via OIDC). The Jenkins IRSA role is added to `aws-auth` by Terraform. |
| ECR authentication | Kaniko uses `ecr-login` credential helper. ECR URL is a Jenkins secret string (`ecr-registry-url`), not hardcoded. |
| GitHub credentials | `github-pat` Jenkins credential (populated by JCasC from `jenkins-credentials` K8s secret). Used by GitHub Branch Source plugin to scan the repo and receive webhooks. |
| Rollback | `kubectl rollout undo deployment/max-weather -n <ns>` — previous ECR image tag is retained by the ECR lifecycle policy (keeps last 10 tagged). |

### Staging Setup (one-time)

Staging runs in a second namespace on the **same** EKS cluster, sharing the same ECR repo. Before the first `develop` push reaches the deploy stage you need a Deployment in `max-weather-staging` that the pipeline can update.

The simplest route is to reuse the existing Helm chart at `gitops/argocd/microservices/max-weather/` (it already ships a `values-staging.yaml`):

```bash
kubectl create namespace max-weather-staging

# Copy the JWT secret used by the staging pods
kubectl get secret max-weather-secrets -n max-weather -o yaml \
  | sed 's/namespace: max-weather/namespace: max-weather-staging/' \
  | kubectl apply -f -

# Install the chart into the staging namespace
helm upgrade --install max-weather \
  gitops/argocd/microservices/max-weather \
  -n max-weather-staging \
  -f gitops/argocd/microservices/max-weather/values-staging.yaml
```

Or add a second ArgoCD `Application` pointing at the same chart with `values-staging.yaml` and `destination.namespace: max-weather-staging`, alongside the existing `max-weather-prod` app in the bootstrap.

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

### Log shipping path

```
pod stdout
   │
   ▼  /var/log/containers/<pod>_<ns>_<container>-<id>.log on the node
Fluent Bit DaemonSet (kube-system, IRSA: max-weather-production-fluent-bit-role)
   │
   ▼  cloudwatch_logs output plugin
CloudWatch Logs: /eks/max-weather/application
   │
   ├──► metric filter MaxWeatherErrorCount    ──► alarm MaxWeather-high-error-rate
   └──► metric filter MaxWeatherAuthRejections ──► alarm MaxWeather-high-auth-rejections
```

### Log Groups

| Log Group | Populated by | Notes |
|---|---|---|
| `/eks/max-weather/application` | Fluent Bit DaemonSet (every pod on every node) | App stdout, ingress-nginx, system pods — all land here. The metric filters run against this group. |
| `/eks/max-weather/nginx` | *(not currently routed)* | Pre-created by terraform for an eventual nginx-only output split (would need a second `cloudwatch_logs` block in the Fluent Bit config + filter on `kube.var.log.containers.*ingress-nginx*`). |
| `/aws/lambda/max-weather-authorizer` | Lambda runtime (no Fluent Bit involved) | Every authorizer invocation. |

### Metric filters → Alarms

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
| `addons` | ArgoCD (Helm), `jenkins-credentials` + `max-weather-secrets` K8s secrets, ArgoCD bootstrap manifest, `aws-auth` patch for Jenkins IRSA |

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

### CI/CD — Smoke Tests + Manual Approval Gate
A namespace-based staging environment is now in place — `develop` pushes deploy to `max-weather-staging` on the same cluster (see *CI/CD Flow* above). What's still missing for a true promotion pipeline:

```
Test → Build → Deploy Staging → Smoke Tests → Manual Approval → Deploy Production
```

Remaining changes in `gitops/jenkins/Jenkinsfile`:
- Add a smoke test stage after `Deploy to Staging` (e.g. `curl` the staging API Gateway URL and assert HTTP 200)
- Add an `input` step (`Proceed to production?`) so a single pipeline run promotes staging → prod, instead of relying on a separate `main` merge
- Stronger isolation: bring up a parallel staging stack via `terraform apply -var environment=staging` (separate VPC, EKS cluster, API Gateway) instead of sharing the production cluster

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
