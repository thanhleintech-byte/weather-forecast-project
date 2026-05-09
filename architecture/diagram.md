# Max Weather — Infrastructure Architecture

## High-Level Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                              AWS Cloud (us-east-1)                              │
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
│  │          AWS API Gateway (HTTP API)    │                                     │
│  │     https://<id>.execute-api.../prod   │                                     │
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
│  │  Public Subnets (10.0.1.0/24, 10.0.2.0/24)  — us-east-1a, us-east-1b  │    │
│  │  ┌──────────────────────────────────────────────────────────────────┐   │    │
│  │  │  AWS Network Load Balancer  (created by Nginx Ingress Service)   │   │    │
│  │  └──────────────────────────┬───────────────────────────────────────┘   │    │
│  │                             │                                           │    │
│  │  Private Subnets (10.0.3.0/24, 10.0.4.0/24) — EKS Worker Nodes        │    │
│  │  ┌──────────────────────────▼───────────────────────────────────────┐  │    │
│  │  │                EKS Cluster  (K8s 1.29)                           │  │    │
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

---

## Component Descriptions

### AWS API Gateway (HTTP API)
Entry point for all external traffic. Configured with a Lambda Authorizer that validates the JWT Bearer token on every protected route before forwarding the request to the backend.

### Lambda Authorizer
Node.js 20.x Lambda function that:
1. Extracts the `Authorization: Bearer <token>` header
2. Fetches the JWT signing secret from AWS Secrets Manager (cached per function instance)
3. Verifies the HS256 JWT (expiry, issuer, audience)
4. Returns an IAM `Allow` or `Deny` policy for `execute-api:Invoke`

### VPC
Multi-AZ design for fault tolerance:
- **2 public subnets** (us-east-1a, us-east-1b) — host the NLB and NAT Gateways
- **2 private subnets** (us-east-1a, us-east-1b) — host EKS worker nodes (no public IPs)
- Internet Gateway for public subnet outbound
- NAT Gateways (one per AZ) for private subnet outbound (EKS nodes pulling images, calling Open-Meteo)

### EKS Cluster
- **Control plane**: managed by AWS, spans all AZs automatically
- **Worker nodes**: `t3.medium`, managed node group, min 2 / max 10 nodes
- **Add-ons**: CoreDNS, kube-proxy, VPC-CNI, IRSA via OIDC provider

### Kubernetes Workloads
| Resource | Purpose |
|---|---|
| `Deployment` | Runs FastAPI containers, 2 initial replicas spread across AZs |
| `Service` (ClusterIP) | Internal load balancing to pods |
| `HPA` | Scales replicas 2–10 based on CPU (70%) and memory (80%) |
| `PodDisruptionBudget` | Guarantees ≥1 pod stays running during node drains |
| Nginx Ingress Controller | Routes external NLB traffic to the Service |
| `Ingress` | Path-based routing rules (/token, /weather/*, /health) |

### High Availability Strategy
- **Multi-AZ**: pods are spread across AZs via `topologySpreadConstraints`
- **Rolling updates**: `maxUnavailable=1, maxSurge=1` ensures zero-downtime deploys
- **PDB**: `minAvailable=1` prevents full outage during cluster operations
- **HPA**: scales up during morning traffic peaks, scales down overnight
- **Probes**: `readinessProbe` prevents sending traffic to unready pods

### CI/CD Pipeline (Jenkins)
```
Git Push → Checkout → Test (pytest) → Docker Build
         → Push ECR → Deploy Staging → Smoke Test
         → Manual Approval → Deploy Production (rolling) → Notify
```
Automatic rollback on production deploy failure.

### CloudWatch Observability
- **Fluent Bit DaemonSet** forwards all pod stdout (JSON-structured) to `/eks/max-weather/application`
- **Metric filters** extract error counts and auth rejection counts
- **Alarms** fire when error rate exceeds threshold or auth rejections spike (security signal)

### Amazon ECR
Private container registry with:
- Image scanning on push (vulnerability detection)
- AES256 encryption at rest
- Lifecycle policy: keep last 10 tagged images, expire untagged after 7 days

---

## Security Posture

| Control | Implementation |
|---|---|
| API Authentication | JWT HS256, validated by Lambda Authorizer |
| Secret Storage | AWS Secrets Manager (JWT key, client secrets) |
| Network isolation | EKS nodes in private subnets, no public IPs |
| Container security | Non-root user, read-only filesystem, dropped capabilities |
| Image scanning | ECR scan on push |
| Rate limiting | Nginx Ingress `limit-rps: 50` per client |
| Audit logging | CloudWatch captures all auth events |
