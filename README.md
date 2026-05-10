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
│  │  https://<api-id>.execute-api.         │                                     │
│  │     <region>.amazonaws.com/<stage>     │                                     │
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
├── app/                                       # FastAPI weather proxy
│   ├── main.py                                #   /health, /token, /weather/{current,forecast,coordinates}
│   ├── Dockerfile                             #   built by Jenkins, pushed to ECR
│   ├── requirements.txt
│   └── tests/                                 #   pytest — runs as the Test stage
├── lambda/authorizer/                         # Node.js 20.x JWT authorizer for API Gateway
│   ├── index.js                               #   Bearer token → HS256 verify → Allow/Deny IAM policy
│   └── package.json
├── terraform/                                 # Four stages, each with its own state
│   ├── network/                               #   Stage 1 — VPC, subnets, IGW, NAT GWs
│   ├── eks/                                   #   Stage 2 — EKS, IAM/IRSA, ECR, CloudWatch
│   ├── argocd/                                #   Stage 3 — ArgoCD helm install + bootstrap apply
│   ├── api-gateway/                           #   Stage 4 — JWT secret, Lambda authorizer, API Gateway
│   └── modules/                               #   Reusable building blocks called by the stages
│       ├── vpc/                               #     VPC + subnets + NAT
│       ├── eks/                               #     Cluster + node group + IRSA roles (app, jenkins, cluster-autoscaler, fluent-bit, ebs-csi)
│       ├── ecr/                               #     Container registry + lifecycle policy
│       ├── iam/                               #     Base IAM roles (cluster, nodes, lambda)
│       ├── cloudwatch/                        #     Log groups + metric filters + alarms
│       ├── lambda_authorizer/                 #     Lambda function (zip-built locally)
│       └── api_gateway/                       #     REST API + TOKEN authorizer + routes
├── gitops/                                    # GitOps source of truth — read by ArgoCD
│   ├── argocd/
│   │   ├── bootstrap.yaml                     #   Single root Application — only YAML terraform applies
│   │   ├── apps/                              #   App-of-apps Helm chart — renders one child Application per component
│   │   │   ├── Chart.yaml
│   │   │   ├── values.yaml                    #     repoURL/revision overridden by the root via helm.values
│   │   │   └── templates/                     #     metrics-server, ingress-nginx, cluster-autoscaler,
│   │   │                                      #     fluent-bit, jenkins, jenkins-pipelines, max-weather-prod
│   │   ├── infra/                             #   Helm wrappers that the child Applications install
│   │   │   ├── metrics-server/
│   │   │   ├── ingress-nginx/
│   │   │   ├── cluster-autoscaler/
│   │   │   ├── fluent-bit/
│   │   │   ├── jenkins/                       #     Helm values + JCasC (GitHub PAT credential, ECR registry URL, …)
│   │   │   └── jenkins-pipelines/             #     ConfigMap registering the max-weather multibranch pipeline (Job DSL)
│   │   └── microservices/max-weather/         #   Helm chart for the FastAPI workload
│   │       ├── Chart.yaml
│   │       ├── values.yaml / values-prod.yaml / values-staging.yaml
│   │       └── templates/                     #     Deployment, Service, Ingress, HPA, PDB, scheduled-scaler (CronJobs)
│   └── jenkins/Jenkinsfile                    # CI/CD pipeline — Jenkins runs this on every webhook
├── postman/
│   └── max-weather-api.postman_collection.json
├── credentials.local.env(.example)            # gitignored — secrets sourced as TF_VAR_* and consumed by every stage
└── README.md                                  # This file
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

### One-time setup

```bash
cp credentials.local.env.example credentials.local.env
$EDITOR credentials.local.env       # GitHub PAT, JWT key, OAuth creds, Jenkins/ArgoCD admin pwds, etc.
source credentials.local.env        # exports TF_VAR_* — every terraform stage reads from here
```

`credentials.local.env` is gitignored and is the **only** place secrets live. There are no per-stage `terraform.tfvars` files for sensitive values.

### Apply the four terraform stages in order

| # | Path | What it provisions | Runtime |
|---|---|---|---|
| 1 | `terraform/network` | VPC, public + private subnets across 2 AZs, IGW, one NAT GW per AZ | ~3 min |
| 2 | `terraform/eks` | EKS control plane, managed node group, ECR repo, CloudWatch log groups + metric filters + alarms, IRSA roles for the app, Jenkins, cluster-autoscaler, Fluent Bit, EBS CSI | ~15 min |
| 3 | `terraform/argocd` | ArgoCD Helm release; pre-creates `jenkins-credentials` / `jenkins-admin-secret` / `max-weather-secrets`; patches `aws-auth` for Jenkins IRSA; applies the GitOps root Application | ~5 min |
| 4 | `terraform/api-gateway` | JWT signing key in Secrets Manager; Lambda authorizer (zip-built locally); REST API + TOKEN authorizer + routes pointing at the public ingress hostname | ~1 min |

```bash
cd terraform/network    && terraform init && terraform apply
cd ../eks               && terraform init && terraform apply
cd ../argocd            && terraform init && terraform apply
cd ../api-gateway       && terraform init && terraform apply
```

Each stage holds its own state. Stages 2–4 read upstream outputs via `terraform_remote_state`, so you can re-run any one of them independently without touching the others.

### What happens after Stage 3 (ArgoCD)

Stage 3 is the handoff point. After it returns, terraform's job is done for the in-cluster platform — ArgoCD takes over and finishes wiring everything from `gitops/argocd/`:

1. **The `bootstrap` root Application** (the one manifest terraform applied) renders the `gitops/argocd/apps/` Helm chart, producing **7 child Applications**:
   - `metrics-server` — required by HPA
   - `ingress-nginx` — creates the public NLB
   - `cluster-autoscaler` — drives the node-group ASG up/down
   - `fluent-bit` — DaemonSet shipping every pod's stdout to CloudWatch
   - `jenkins` — Jenkins controller, **preconfigured via JCasC** with the `github-pat` credential populated from the `jenkins-credentials` K8s secret (which Stage 3 created)
   - `jenkins-pipelines` — ConfigMap registering the `max-weather` multibranch pipeline via Job DSL; points Jenkins at this repo and at `gitops/jenkins/Jenkinsfile`
   - `max-weather-prod` — the FastAPI workload (Deployment, Service, Ingress, HPA, PDB, scheduled scaler)

2. **Jenkins boots and immediately scans GitHub** using `github-pat`. It discovers the `main` branch, finds the multibranch pipeline definition, and triggers the first run automatically:
   - **Test** — pytest in a `python:3.12` agent
   - **Build & Push** — Kaniko builds `app/Dockerfile` and pushes `:<build#>` and `:latest` to ECR (using the Jenkins IRSA role, no static AWS keys)
   - **Deploy to Production** — `kubectl set image deployment/max-weather max-weather=<new-image> -n max-weather`, then `kubectl rollout status`

   The `max-weather` Deployment was already created by ArgoCD in step 1 with `:latest`, so the deploy stage is just a rolling update from a placeholder to the freshly-pushed image.

So **no manual `docker build` / `docker push` is required.** The first commit to `main` after Jenkins is online (which can be the same commit that ran terraform) produces the production image and rolls the Deployment.

### After all four stages

```bash
$(terraform -chdir=terraform/eks output -raw kubeconfig_command)        # configure kubectl
kubectl get nodes                                                        # all Ready
kubectl -n argocd get applications                                       # all Synced + Healthy
terraform -chdir=terraform/api-gateway output api_gateway_url            # public API URL
```

End-to-end test with the included [Postman collection](./postman/max-weather-api.postman_collection.json) — see *Testing with Postman* below.

### Key outputs

| Output (stage) | Description |
|---|---|
| `cluster_name` (eks) | EKS cluster name |
| `ecr_repository_url` (eks) | ECR registry URL — Jenkins pushes here |
| `kubeconfig_command` (eks) | Ready-to-eval `aws eks update-kubeconfig …` |
| `api_gateway_url` (api-gateway) | Public API Gateway invoke URL |
| `lambda_authorizer_role_arn` (eks) | Lambda authorizer execution role |

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
      │           <account-id>.dkr.ecr.<region>.amazonaws.com/max-weather:<build-number>
      │           <account-id>.dkr.ecr.<region>.amazonaws.com/max-weather:<latest|staging>
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
| Staging namespace prerequisite | The pipeline calls `kubectl set image` against an existing `Deployment/max-weather` in `max-weather-staging` — that deployment must already exist (install the chart from `gitops/argocd/microservices/max-weather/` with `values-staging.yaml` into the `max-weather-staging` namespace) or the deploy step fails. |
| No static AWS keys in cluster | Jenkins uses IRSA (IAM role bound to K8s ServiceAccount via OIDC). The Jenkins IRSA role is added to `aws-auth` by Terraform. |
| ECR authentication | Kaniko uses `ecr-login` credential helper. ECR URL is a Jenkins secret string (`ecr-registry-url`), not hardcoded. |
| GitHub credentials | `github-pat` Jenkins credential (populated by JCasC from `jenkins-credentials` K8s secret). Used by GitHub Branch Source plugin to scan the repo and receive webhooks. |
| Rollback | `kubectl rollout undo deployment/max-weather -n <ns>` — previous ECR image tag is retained by the ECR lifecycle policy (keeps last 10 tagged). |


---

## API Gateway + Lambda Authorizer

### Route Map

| Method | Path | Auth | Backend |
|--------|------|------|---------|
| `GET` | `/health` | None | `https://${TF_VAR_app_host}/health` |
| `POST` | `/token` | None | `https://${TF_VAR_app_host}/token` |
| `ANY` | `/weather/{proxy+}` | JWT required | `https://${TF_VAR_app_host}/weather/{proxy}` |

**Base URL:** `https://<api-id>.execute-api.<region>.amazonaws.com/<stage>` — printed as `api_gateway_url` by the `terraform/api-gateway` stage.

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
2. Set collection variable `base_url` to the value of `terraform -chdir=terraform/api-gateway output -raw api_gateway_url`
3. Run **Get Access Token** (`POST /token`) — test script auto-saves the JWT to `access_token`
4. Run the `/weather/*` requests — they send `Authorization: Bearer {{access_token}}` automatically
5. Run **Unauthorized Request** — expect 401/403

Default credentials: `client_id` = `max-weather-client`, `client_secret` = `super-secret-key`

---

## Secrets & External Configuration

Every sensitive value lives in one gitignored file — `credentials.local.env` — sourced as `TF_VAR_*` environment variables before each `terraform apply`. Terraform then writes what's needed into AWS Secrets Manager and Kubernetes Secrets. No plaintext is ever committed.

> **No AWS access keys required.** Jenkins authenticates to AWS via IRSA on its ServiceAccount; your local `aws` CLI uses your existing profile.

### Single source: `credentials.local.env`

Copy `credentials.local.env.example` and fill in:

| `TF_VAR_…` | Description |
|---|---|
| `github_repo_url` | HTTPS URL of this repo (e.g. `https://github.com/<owner>/<repo>.git`) |
| `github_username` | GitHub username paired with the PAT |
| `github_pat` | GitHub Personal Access Token, scope `repo` |
| `jwt_secret_value` | Random base64 32-byte key (HS256). The `api-gateway` stage writes this into AWS Secrets Manager. |
| `oauth_client_id` / `oauth_client_secret` | Demo OAuth2 client credentials for `POST /token` |
| `argocd_admin_password` | Plaintext; terraform bcrypt-hashes it before passing to the ArgoCD Helm release |
| `jenkins_admin_password` | Plaintext; terraform writes it to `jenkins-admin-secret`, which the Jenkins Helm chart mounts via `controller.admin.existingSecret` |
| `app_host` | Public hostname for the Nginx ingress (e.g. `max-weather.example.com`) — used by the API Gateway HTTP_PROXY integration |
| `argocd_hostname` | Public hostname for the ArgoCD UI (empty = no ingress, port-forward only) |

### What terraform creates from those values

| Resource | Created in stage | Source `TF_VAR_*` | Consumed by |
|---|---|---|---|
| Secrets Manager `max-weather/jwt-secret` | `api-gateway` | `jwt_secret_value` | Lambda Authorizer (HS256 verify), FastAPI app (token signing) |
| K8s Secret `jenkins-credentials` (ns `jenkins`) | `argocd` | `github_pat`, `github_username` | JCasC → Jenkins credential `github-pat` |
| K8s Secret `jenkins-admin-secret` (ns `jenkins`) | `argocd` | `jenkins_admin_password` | Jenkins Helm chart admin login |
| K8s Secret `max-weather-secrets` (ns `max-weather`) | `argocd` | `jwt_secret_value`, `oauth_client_id`, `oauth_client_secret` | FastAPI pods (env vars) |
| ArgoCD admin password | `argocd` | `argocd_admin_password` (bcrypt-hashed, cached so applies don't churn the Helm release) | ArgoCD UI/CLI login |

Rotate any value by editing `credentials.local.env`, sourcing it, and re-running the relevant stage. Terraform triggers are keyed on value hashes, so unrelated resources stay put.

### Jenkins credentials store (auto-populated by JCasC on first boot)

| Credential ID | Type | Source |
|---|---|---|
| `github-pat` | Username/Password | `${GITHUB_USERNAME}` / `${GITHUB_PAT}` from `jenkins-credentials` |
| `ecr-registry-url` | Secret string | Hardcoded in `gitops/argocd/infra/jenkins/values.yaml` |
| `aws-region` | Secret string | `ap-south-1` |

The Jenkinsfile reads `ecr-registry-url` via `credentials('ecr-registry-url')`. AWS access for the pipeline is via the Jenkins ServiceAccount's IRSA role — no static AWS credentials anywhere.

### Admin UIs

| Service | URL | Username | Password |
|---|---|---|---|
| ArgoCD | `https://${TF_VAR_argocd_hostname}` *or* `kubectl -n argocd port-forward svc/argocd-server 8080:443` | `admin` | `${TF_VAR_argocd_admin_password}` |
| Jenkins | configured via the Jenkins Helm chart's `controller.ingress.hostName` *or* `kubectl -n jenkins port-forward svc/jenkins 8080:8080` | `admin` | `${TF_VAR_jenkins_admin_password}` |

### Application demo credentials

Hardcoded in `app/main.py` for the `POST /token` endpoint — change before any public-facing deployment.

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

Reusable modules under `terraform/modules/`. The four stage roots compose them.

| Module | Resources Created |
|---|---|
| `vpc` | VPC, public/private subnets across 2 AZs, IGW, route tables, one NAT GW per AZ |
| `eks` | EKS cluster + managed node group, EKS add-ons (CoreDNS, kube-proxy, VPC-CNI, EBS-CSI), OIDC provider, IRSA roles for the EBS CSI driver, Jenkins, Cluster Autoscaler, and Fluent Bit |
| `ecr` | ECR repository with image scanning + lifecycle policy |
| `iam` | Base EKS cluster role, node role, Lambda execution role |
| `cloudwatch` | Log groups (`/eks/<project>/application`, `/eks/<project>/nginx`, `/aws/lambda/<project>-authorizer`), metric filters, alarms |
| `lambda_authorizer` | Lambda function (zip-built locally) + API Gateway invoke permission |
| `api_gateway` | REST API, TOKEN authorizer, routes, `prod` stage |

All modules accept `project_name` and `environment` — set `environment = "staging"` to spin up a parallel stack with isolated state.

---

## Potential Enhancements

### API Gateway — VPC Link (PrivateLink)
Currently API Gateway reaches the backend via the **public internet**: it resolves the configured `app_host` to the NLB's public DNS and sends traffic over the open internet. The NLB is therefore internet-reachable, meaning a client who discovers the NLB hostname can bypass API Gateway and the Lambda Authorizer entirely.

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

### JWT — Asymmetric Signing (RS256)
The current implementation uses HS256 with a shared secret. For a multi-service setup, RS256 is preferable: the app signs with a private key; any service can verify with the public key without ever seeing the private key. The Lambda Authorizer would fetch the public key (or JWKS endpoint) rather than the shared secret.

---

### CloudWatch — Dashboard
Log groups, metric filters, and alarms are provisioned but there is no CloudWatch Dashboard. Add an `aws_cloudwatch_dashboard` resource to `terraform/modules/cloudwatch/main.tf` to surface request rate, error rate, auth rejection rate, HPA replica count, and pod CPU/memory in a single view.

---

### Centralized secrets — External Secrets Operator

Today terraform writes the JWT signing key into AWS Secrets Manager **and** copies it into a Kubernetes Secret in the `argocd` stage so the FastAPI pods can mount it as env vars. That duplication means rotating the value requires editing `credentials.local.env` and re-running `terraform apply`.

Replace it with **External Secrets Operator (ESO)**:

- Install ESO via a new ArgoCD Application (`gitops/argocd/infra/external-secrets/`).
- Define a `SecretStore` (or `ClusterSecretStore`) authenticated to AWS via IRSA (`secretsmanager:GetSecretValue` scoped to `max-weather/*`).
- Define an `ExternalSecret` per consuming workload that points at the Secrets Manager entry; ESO materialises a regular `Secret` and keeps it in sync.
- Delete `kubernetes_secret.max_weather` from `terraform/argocd/main.tf`.

Result: AWS Secrets Manager becomes the single source of truth. Rotation is a one-call Secrets Manager update — no terraform, no Helm release churn.

---

### CI/CD — Security scanning + Terraform tests

The Jenkinsfile currently runs only `pytest`. A defence-in-depth pipeline adds parallel scanning stages that fail the build before vulnerable code or secrets reach the registry / cluster:

| Stage | Tool | What it catches |
|---|---|---|
| Credential leak scan | `gitleaks`, `trufflehog` | API keys / AWS credentials / JWT secrets accidentally committed |
| Container image scan | `trivy image` against the freshly-built ECR tag | Known CVEs in base image and Python deps; fail on `HIGH`/`CRITICAL` |
| Dependency scan | `pip-audit` (Python), Dependabot / Snyk (transitive) | Vulnerable libraries pinned in `requirements.txt` / `package.json` |
| K8s manifest scan | `trivy config`, `kubesec` against `gitops/.../templates/*.yaml` | Privileged pods, missing resource limits, root filesystem, etc. |
| Terraform code scan | `tfsec`, `checkov` against `terraform/` | Public S3 buckets, unencrypted volumes, wildcard IAM, missing tags |
| Terraform unit tests | `.tftest.hcl` (native, since 1.6) or Terratest | Resource shape under different inputs — e.g. that `cloudwatch` alarm thresholds and `eks` HPA bounds match the variables, without a full `apply` |

All scanners emit SARIF for PR-level annotations and JUnit XML for the Jenkins UI. Wiring them in parallel keeps total pipeline time close to the current single-stage run.

---

### EKS API server — private endpoint + bastion / VPN

The cluster's API server is currently public (`endpoint_public_access = true` in `terraform/modules/eks/main.tf`). Anyone on the internet can probe it for misconfigurations or zero-days.

Production hardening path:

1. Flip the EKS endpoint config: `endpoint_public_access = false`, `endpoint_private_access = true`. The API server then resolves only to a private IP inside the VPC.
2. Provide an in-VPC entry point for operators:
   - **AWS Client VPN** in the same VPC (mutual-TLS auth, ~$0.10/hr per active association) — best for distributed operator access from anywhere.
   - **Bastion host** (small EC2 in a public subnet, no SSH keys, accessed via SSM Session Manager) — cheapest; operators run `aws ssm start-session` then `kubectl` from the bastion.
3. Update the Cloudflare side: nothing — API Gateway is already the only ingress for end-user traffic, and it lives outside the VPC. Combined with *API Gateway VPC Link* above, the resulting topology has **only one component reachable from the internet — the API Gateway URL**.
4. Jenkins is unaffected (it's already inside the cluster). Local `kubectl` / `terraform apply` for stages 2-4 must traverse the VPN or bastion.

---

### API Gateway — WAF & Throttling
API Gateway is currently open to the internet without rate limiting at the AWS layer (rate limiting is only enforced at the Nginx layer inside the cluster). Additions worth considering:

- Attach an AWS WAF Web ACL to the API Gateway stage for IP-based blocking and managed rule sets
- Configure per-stage throttling (`default_route_settings`) to cap burst and steady-state request rates
- Add API usage plans and API keys for client-level quota management

---

## Tear Down

Destroy in **reverse order** of apply, since later stages read state from earlier ones via `terraform_remote_state`:

```bash
cd terraform/api-gateway && terraform destroy
cd ../argocd             && terraform destroy
cd ../eks                && terraform destroy
cd ../network            && terraform destroy
```

If `argocd` destroy hangs on ArgoCD `Application` finalizers, force-clear them first:

```bash
kubectl -n argocd get applications -o name \
  | xargs -I {} kubectl -n argocd patch {} --type=merge \
      -p '{"metadata":{"finalizers":[]}}'
```

The `api-gateway` stage manages the JWT signing key in Secrets Manager and removes it on destroy. The Cloudflare DNS records pointing at the old NLB are not managed by terraform; clean those up manually.
