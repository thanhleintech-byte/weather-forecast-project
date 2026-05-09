# Max Weather Platform

Production-ready weather forecasting API on AWS EKS — high availability, auto-scaling, OAuth2-secured, CI/CD deployed.

## Architecture

See [`architecture/diagram.md`](architecture/diagram.md) for the full infrastructure diagram and component descriptions.

**Stack summary:**
- **App**: Python FastAPI → [Open-Meteo](https://open-meteo.com/) (free, no API key needed)
- **Auth**: OAuth2 Bearer JWT (HS256), validated by AWS Lambda Authorizer
- **Infra**: AWS EKS (K8s 1.32), VPC multi-AZ, ECR, API Gateway, CloudWatch
- **IaC**: Terraform (modularised, 6 modules)
- **CI/CD**: Jenkins declarative pipeline (test → staging → approval → production)

---

## Project Structure

```
max-weather/
├── architecture/diagram.md          # Full infrastructure diagram
├── app/                             # FastAPI application
│   ├── main.py
│   ├── requirements.txt
│   ├── Dockerfile
│   └── tests/test_main.py
├── kubernetes/                      # K8s manifests
│   ├── namespace.yaml
│   ├── deployment.yaml
│   ├── service.yaml
│   ├── hpa.yaml
│   ├── pdb.yaml
│   ├── nginx-ingress-controller.yaml
│   └── ingress.yaml
├── terraform/                       # Infrastructure as Code
│   ├── main.tf / variables.tf / outputs.tf / versions.tf
│   ├── terraform.tfvars.example
│   └── modules/
│       ├── vpc/
│       ├── eks/
│       ├── ecr/
│       ├── iam/
│       ├── cloudwatch/
│       └── lambda_authorizer/
├── lambda/authorizer/               # JWT Lambda Authorizer (Node.js)
│   ├── index.js
│   └── package.json
├── jenkins/Jenkinsfile              # CI/CD pipeline
└── postman/                         # API test collection
    └── max-weather.postman_collection.json
```

---

## Quick Start — Running Locally

```bash
cd app
pip install -r requirements.txt

# Start the API
JWT_SECRET="your-32-char-minimum-secret-key!!" uvicorn main:app --reload

# In another terminal — get a token
curl -X POST http://localhost:8000/token \
  -d "username=max-weather-client&password=super-secret-key"

# Use the token
TOKEN="<paste_access_token_here>"

curl -H "Authorization: Bearer $TOKEN" \
  "http://localhost:8000/weather/current?city=Singapore"

curl -H "Authorization: Bearer $TOKEN" \
  "http://localhost:8000/weather/forecast?city=London&days=5"

curl -H "Authorization: Bearer $TOKEN" \
  "http://localhost:8000/weather/coordinates?lat=1.3521&lon=103.8198"
```

Interactive API docs at http://localhost:8000/docs

### Run Tests

```bash
cd app
python -m pytest tests/ -v
```

---

## Deploying to AWS

### Prerequisites

- AWS CLI configured with sufficient IAM permissions
- Terraform >= 1.6.0
- kubectl
- Docker

### Step 1 — Prerequisites

| Tool | Minimum version |
|------|----------------|
| Terraform | 1.6.0 |
| AWS CLI | 2.x |
| kubectl | 1.32.x |
| Docker | 24.x |
| Node.js | 20.x |

AWS credentials must have permissions for: `EKS`, `EC2`, `IAM`, `ECR`, `Lambda`, `CloudWatch`, `SecretsManager`.

### Step 2 — Create the JWT Secret

Run this once before the first `terraform apply`. The returned ARN is required as a Terraform variable.

```bash
aws secretsmanager create-secret \
  --name "max-weather/jwt-secret" \
  --secret-string "$(openssl rand -base64 32)" \
  --region ap-south-1
```

Note the returned `ARN`.

### Step 3 — Provision Infrastructure

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars — set aws_region, environment, jwt_secret_arn

terraform init
terraform plan          # review before applying
terraform apply
```

Typical apply time: **20–25 minutes** (EKS control plane ~8 min, node group ~3 min).

> **Supported Kubernetes versions** for new node groups: 1.30–1.35. Use `1.32` or later — versions below 1.30 have retired node AMIs.

After apply, retrieve all outputs:

```bash
terraform output
```

### Step 4 — Configure kubectl

```bash
aws eks update-kubeconfig --region ap-south-1 --name max-weather-production
kubectl get nodes    # should show 2× t3.medium in Ready state
```

### Step 5 — Build and Push the Docker Image

```bash
ECR_URL=$(terraform -chdir=terraform output -raw ecr_repository_url)

aws ecr get-login-password --region ap-south-1 \
  | docker login --username AWS --password-stdin $ECR_URL

docker build -t max-weather ./app
docker tag  max-weather:latest $ECR_URL:latest
docker push $ECR_URL:latest
```

### Step 6 — Deploy to Kubernetes

```bash
# Namespace
kubectl apply -f kubernetes/namespace.yaml

# ServiceAccount with IRSA annotation (allows CloudWatch log writes)
IRSA_ARN=$(terraform -chdir=terraform output -raw app_irsa_role_arn)
kubectl create serviceaccount max-weather-sa -n max-weather --dry-run=client -o yaml \
  | kubectl apply -f -
kubectl annotate serviceaccount max-weather-sa \
  eks.amazonaws.com/role-arn=$IRSA_ARN -n max-weather

# Update the image in the deployment manifest before applying
ECR_URL=$(terraform -chdir=terraform output -raw ecr_repository_url)
sed -i "s|<ECR_REPO>|$ECR_URL:latest|g" kubernetes/deployment.yaml

# Apply all manifests
kubectl apply -f kubernetes/nginx-ingress-controller.yaml
kubectl apply -f kubernetes/deployment.yaml
kubectl apply -f kubernetes/service.yaml
kubectl apply -f kubernetes/hpa.yaml
kubectl apply -f kubernetes/pdb.yaml
kubectl apply -f kubernetes/ingress.yaml

# Verify
kubectl get pods   -n max-weather
kubectl get hpa    -n max-weather
kubectl get ingress -n max-weather   # note the ALB hostname
```

### Step 7 — Configure API Gateway (AWS Console)

> The assignment permits manual API Gateway setup via the console.

1. **Create a REST API** → name it `max-weather`
2. **Resource**: `/{proxy+}` with `ANY` method, integration type **HTTP Proxy**, endpoint = Nginx Ingress ALB hostname
3. **Lambda Authorizer**:
   - Type: **TOKEN**
   - Lambda: `max-weather-authorizer-production`
   - Token source: `Authorization`
   - Token validation regex: `^Bearer .+`
   - TTL: `300`
4. **Attach** the authorizer to the `/{proxy+} ANY` method
5. **Deploy** → new stage `production` → note the **Invoke URL**

### Step 8 — Test with Postman

Generate a test JWT:

```bash
SECRET=$(aws secretsmanager get-secret-value \
  --secret-id max-weather/jwt-secret \
  --region ap-south-1 \
  --query SecretString --output text)

node -e "
  const jwt = require('jsonwebtoken');
  console.log(jwt.sign(
    { sub: 'test-client', iss: 'max-weather', aud: 'max-weather-api' },
    '$SECRET',
    { algorithm: 'HS256', expiresIn: '1h' }
  ));
"
```

Then:

1. Import `postman/max-weather.postman_collection.json`
2. Set collection variable `base_url` to the API Gateway Invoke URL
3. Set `Authorization: Bearer <token>` in the collection headers
4. Run all requests — authenticated calls should return 200, unauthenticated should return 401

---

## Tear Down

```bash
cd terraform
terraform destroy

# Also remove the JWT secret
aws secretsmanager delete-secret \
  --secret-id max-weather/jwt-secret \
  --region ap-south-1 \
  --force-delete-without-recovery
```

---

## Deployed Resources (ap-south-1, account 047750375423)

| Resource | Value |
|----------|-------|
| VPC | `vpc-06a09cf8e730e309f` |
| EKS Cluster | `max-weather-production` (Kubernetes 1.32) |
| ECR | `047750375423.dkr.ecr.ap-south-1.amazonaws.com/max-weather` |
| Lambda Authorizer | `arn:aws:lambda:ap-south-1:047750375423:function:max-weather-authorizer-production` |
| IRSA Role | `arn:aws:iam::047750375423:role/max-weather-production-app-irsa-role` |
| JWT Secret | `arn:aws:secretsmanager:ap-south-1:047750375423:secret:max-weather/jwt-secret-VFpr5F` |
| CW Log Group (app) | `/eks/max-weather/application` |
| CW Log Group (nginx) | `/eks/max-weather/nginx` |

---

## Key Design Decisions

| Decision | Rationale |
|---|---|
| Open-Meteo API | Free, no API key, reliable, supports geocoding + forecast |
| JWT HS256 over asymmetric | Simpler for single-service; secret stored in Secrets Manager |
| HPA CPU 70% threshold | Leaves headroom before degradation; aggressive enough to handle morning spike |
| `single_nat_gateway = false` | One NAT GW per AZ eliminates cross-AZ traffic on outbound calls |
| `topologySpreadConstraints` | Ensures pods survive a full AZ failure |
| Fluent Bit DaemonSet | Decouples logging from app code; standard EKS pattern |
| `PodDisruptionBudget` | Critical for zero-downtime node upgrades and spot terminations |

---

## Terraform Modules

| Module | Resources Created |
|---|---|
| `vpc` | VPC, public/private subnets, IGW, NAT GWs, route tables |
| `eks` | EKS cluster, managed node group, OIDC provider, add-ons |
| `ecr` | ECR repository + lifecycle policy |
| `iam` | EKS roles, node role, IRSA role, Lambda role |
| `cloudwatch` | Log groups, metric filters, alarms |
| `lambda_authorizer` | Lambda function, permission for API Gateway |

All modules accept `project_name` and `environment` variables so the entire stack can be duplicated for staging by changing only `environment = "staging"`.

---

## Environment Variables

| Variable | Required | Description |
|---|---|---|
| `JWT_SECRET` | Yes | HS256 signing key (min 32 chars). Set via K8s Secret. |

Demo credentials (change before production use):

| `client_id` | `client_secret` |
|---|---|
| `max-weather-client` | `super-secret-key` |
