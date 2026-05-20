# EKS Component Deployment Methods — Complete Guide

## Overview

This document covers every way you can deploy each component in the recommended EKS architecture, why one approach wins over the others, and what tradeoffs to expect.

---

## Recommended Architecture Recap

```
LAYER 1 — Terraform        → EKS Cluster + IAM + AWS-coupled addons
LAYER 2 — Harness GitOps   → Platform components (ingress, cert-manager, CRDs)
LAYER 3 — Harness CD       → Application deployments + environment promotion
```

---

## LAYER 1 — TERRAFORM

---

### 1. EKS Cluster

#### Deployment Methods

| # | Method | Tool | Description |
|---|---|---|---|
| 1 | **Terraform EKS Module** | Terraform | `terraform-aws-modules/eks` — most common, opinionated |
| 2 | **Terraform AWS Resources** | Terraform | Raw `aws_eks_cluster`, `aws_eks_node_group` resources — full control |
| 3 | **eksctl** | CLI | YAML-driven CLI tool by Weaveworks |
| 4 | **AWS Console** | UI | Manual click-through in AWS Console |
| 5 | **AWS CDK** | CDK | Infrastructure as code using Python/TypeScript |
| 6 | **Pulumi** | Pulumi | Like Terraform but uses real programming languages |
| 7 | **Harness IaCM** | Harness | Terraform runner inside Harness pipelines |

#### Why Terraform EKS Module Wins

```hcl
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = "my-cluster"
  cluster_version = "1.29"
  vpc_id          = module.vpc.vpc_id
  subnet_ids      = module.vpc.private_subnets

  eks_managed_node_groups = {
    general = {
      instance_types = ["m5.large"]
      min_size       = 2
      max_size       = 5
      desired_size   = 2
    }
  }
}
```

- **Single state file** covers VPC + EKS + IAM + node groups together
- **Output chaining** — `module.eks.cluster_name` flows directly into addon configs
- **Reproducible** — same code produces identical clusters every time
- **Drift detection** — `terraform plan` shows any manual changes
- **Team collaboration** — remote state in S3 + DynamoDB locking
- eksctl has no state management — no way to track drift
- AWS Console has no audit trail and is error-prone
- CDK/Pulumi are powerful but require programming language expertise

---

### 2. VPC, Subnets, Security Groups

#### Deployment Methods

| # | Method | Tool |
|---|---|---|
| 1 | **Terraform VPC Module** | Terraform |
| 2 | **Terraform raw AWS resources** | Terraform |
| 3 | **AWS CloudFormation** | CloudFormation |
| 4 | **AWS Console** | Manual |
| 5 | **AWS CDK** | CDK |
| 6 | **Pulumi** | Pulumi |
| 7 | **Ansible** | Ansible |

#### Why Terraform Wins

```hcl
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "eks-vpc"
  cidr = "10.0.0.0/16"

  azs             = ["eu-west-1a", "eu-west-1b", "eu-west-1c"]
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]

  enable_nat_gateway = true

  tags = {
    "kubernetes.io/cluster/my-cluster" = "shared"
  }
}
```

- VPC and EKS live in the **same state** — dependency graph is automatic
- CloudFormation is AWS-only and harder to read/write
- Ansible is not idempotent for infrastructure — designed for config management
- Terraform modules handle complex subnet tagging requirements for EKS automatically

---

### 3. IAM Roles (IRSA — IAM Roles for Service Accounts)

#### Deployment Methods

| # | Method | Tool |
|---|---|---|
| 1 | **Terraform `aws_iam_role` + OIDC** | Terraform |
| 2 | **Terraform EKS Pod Identity module** | Terraform |
| 3 | **eksctl `iamserviceaccount`** | eksctl CLI |
| 4 | **AWS Console** | Manual |
| 5 | **AWS CDK** | CDK |
| 6 | **Pulumi** | Pulumi |

#### Why Terraform Wins

```hcl
# OIDC provider from EKS cluster
data "tls_certificate" "eks" {
  url = module.eks.cluster_oidc_issuer_url
}

resource "aws_iam_openid_connect_provider" "eks" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks.certificates[0].sha1_fingerprint]
  url             = module.eks.cluster_oidc_issuer_url
}

# IAM Role for LB Controller
resource "aws_iam_role" "lb_controller" {
  name = "eks-lb-controller"

  assume_role_policy = jsonencode({
    Statement = [{
      Action = "sts:AssumeRoleWithWebIdentity"
      Effect = "Allow"
      Principal = {
        Federated = aws_iam_openid_connect_provider.eks.arn
      }
      Condition = {
        StringEquals = {
          "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:sub" = 
            "system:serviceaccount:kube-system:aws-load-balancer-controller"
        }
      }
    }]
  })
}
```

- IAM roles **reference EKS OIDC URL** directly from module output — impossible to do this cleanly outside Terraform
- eksctl creates IAM roles but leaves them untracked in Terraform state — causes drift
- Manual console setup is error-prone and creates no audit trail
- Terraform enforces least-privilege and makes role policies reviewable via PR

---

### 4. AWS Load Balancer Controller

#### Deployment Methods

| # | Method | Tool |
|---|---|---|
| 1 | **Terraform Helm provider** | Terraform |
| 2 | **Helm CLI standalone** | Helm |
| 3 | **eksctl managed addon** | eksctl |
| 4 | **Harness CD Pipeline** | Harness Agent |
| 5 | **Harness GitOps (Argo CD)** | GitOps |
| 6 | **kubectl apply** | kubectl |
| 7 | **AWS EKS Addon (managed)** | AWS Console / Terraform |

#### Why Terraform Wins for LB Controller

```hcl
resource "helm_release" "aws_lb_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  namespace  = "kube-system"
  version    = "1.7.1"

  set {
    name  = "clusterName"
    value = module.eks.cluster_name     # direct reference
  }
  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = aws_iam_role.lb_controller.arn  # direct reference
  }

  depends_on = [
    module.eks,
    aws_iam_role.lb_controller
  ]
}
```

- **Tight coupling with IAM** — the role ARN is referenced directly, no copy-pasting
- `depends_on` ensures cluster is ready before installing the controller
- GitOps cannot easily reference dynamic AWS ARNs from Terraform state
- Helm CLI standalone has no state — if someone changes values manually, no one knows
- LB Controller is infrastructure-level, not app-level — belongs with infra tooling

---

### 5. EBS CSI Driver

#### Deployment Methods

| # | Method | Tool |
|---|---|---|
| 1 | **Terraform EKS Addon resource** | Terraform |
| 2 | **Terraform Helm provider** | Terraform |
| 3 | **AWS Console EKS Addon** | AWS Console |
| 4 | **eksctl** | eksctl |
| 5 | **Helm CLI** | Helm |
| 6 | **Harness GitOps** | GitOps |

#### Why Terraform EKS Addon Resource Wins

```hcl
resource "aws_eks_addon" "ebs_csi" {
  cluster_name             = module.eks.cluster_name
  addon_name               = "aws-ebs-csi-driver"
  addon_version            = "v1.28.0-eksbuild.1"
  service_account_role_arn = aws_iam_role.ebs_csi.arn
  resolve_conflicts_on_update = "PRESERVE"
}
```

- AWS-managed addon — AWS handles upgrades and security patches
- Tracked in Terraform state alongside the cluster
- Direct IAM role reference via IRSA
- Console-managed addons have no IaC audit trail

---

## LAYER 2 — HARNESS GITOPS (Argo CD)

---

### 6. NGINX Ingress Controller

#### Deployment Methods

| # | Method | Tool |
|---|---|---|
| 1 | **Harness GitOps (Argo CD Application)** | GitOps |
| 2 | **Terraform Helm provider** | Terraform |
| 3 | **Helm CLI** | Helm |
| 4 | **Harness CD Pipeline** | Harness Agent |
| 5 | **kubectl apply** | kubectl |
| 6 | **Helmfile** | Helmfile |
| 7 | **Flux CD** | GitOps (alternative) |

#### Why Harness GitOps Wins for NGINX Ingress

```yaml
# Git repo: apps/nginx-ingress/values.yaml
controller:
  replicaCount: 2
  service:
    type: LoadBalancer
    annotations:
      service.beta.kubernetes.io/aws-load-balancer-type: "nlb"
  metrics:
    enabled: true

# Argo CD Application (managed by Harness GitOps)
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: nginx-ingress
spec:
  source:
    repoURL: https://kubernetes.github.io/ingress-nginx
    chart: ingress-nginx
    targetRevision: "4.10.0"
    helm:
      valueFiles:
        - values.yaml
  destination:
    namespace: ingress-nginx
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

- **selfHeal: true** — if someone manually scales down replicas, Argo CD reverts it automatically
- Git PR = deployment — no pipeline needed, no manual commands
- NGINX Ingress values change occasionally (annotations, replica counts) — GitOps handles iterative changes better than Terraform
- Terraform state bloat — every `helm_release` adds to state size and complexity
- Helm CLI has no drift detection — someone could `helm upgrade` manually and nothing tracks it
- Harness CD pipeline is overkill for a platform component that rarely needs approval gates

---

### 7. cert-manager

#### Deployment Methods

| # | Method | Tool |
|---|---|---|
| 1 | **Harness GitOps (Argo CD)** | GitOps |
| 2 | **Terraform Helm provider** | Terraform |
| 3 | **Helm CLI** | Helm |
| 4 | **Harness CD Pipeline** | Harness Agent |
| 5 | **kubectl apply (static manifests)** | kubectl |
| 6 | **Operator Lifecycle Manager (OLM)** | OLM |

#### Why Harness GitOps Wins for cert-manager

```yaml
# Git repo: apps/cert-manager/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - https://github.com/cert-manager/cert-manager/releases/download/v1.14.4/cert-manager.yaml
patches:
  - patch: |-
      - op: replace
        path: /spec/replicas
        value: 2
    target:
      kind: Deployment
      name: cert-manager
```

- cert-manager includes **CRDs** — GitOps handles CRD lifecycle cleanly
- cert-manager upgrades involve CRD changes — Git diff makes this reviewable before applying
- Terraform has known issues managing CRDs (ordering problems, state conflicts)
- `selfHeal` ensures cert-manager is always running even after accidental deletion
- Changes go through PR review — critical for a security component managing TLS certs

---

### 8. TargetGroup Binding CRDs

#### Deployment Methods

| # | Method | Tool |
|---|---|---|
| 1 | **Harness GitOps (Argo CD)** | GitOps |
| 2 | **Terraform Kubernetes provider** | Terraform |
| 3 | **kubectl apply** | kubectl |
| 4 | **Helm CLI** | Helm |
| 5 | **Harness CD Pipeline** | Harness Agent |
| 6 | **Kustomize standalone** | Kustomize |

#### Why Harness GitOps Wins for TargetGroup Binding CRDs

```yaml
# Git repo: apps/targetgroup-binding/targetgroupbinding.yaml
apiVersion: elbv2.k8s.aws/v1beta1
kind: TargetGroupBinding
metadata:
  name: my-service-tgb
  namespace: default
spec:
  serviceRef:
    name: my-service
    port: 80
  targetGroupARN: arn:aws:elasticloadbalancing:eu-west-1:123:targetgroup/my-tg/abc
  targetType: ip
```

- CRDs are **cluster-wide config** — belongs in GitOps layer not app pipeline
- Argo CD handles CRD installation order automatically
- Terraform Kubernetes provider struggles with CRDs — can't apply CRD and CR in same plan
- `kubectl apply` is manual — no drift detection, no audit trail
- Git history shows exactly when each TargetGroup binding was added or changed

---

### 9. External Secrets Operator

#### Deployment Methods

| # | Method | Tool |
|---|---|---|
| 1 | **Harness GitOps (Argo CD)** | GitOps |
| 2 | **Terraform Helm provider** | Terraform |
| 3 | **Helm CLI** | Helm |
| 4 | **Harness CD Pipeline** | Harness Agent |
| 5 | **kubectl apply** | kubectl |

#### Why Harness GitOps Wins for External Secrets Operator

```yaml
# Git repo: apps/external-secrets/values.yaml
installCRDs: true
replicaCount: 2
serviceAccount:
  annotations:
    eks.amazonaws.com/role-arn: "arn:aws:iam::123:role/external-secrets"

# ClusterSecretStore pointing to AWS Secrets Manager
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata:
  name: aws-secretsmanager
spec:
  provider:
    aws:
      service: SecretsManager
      region: eu-west-1
      auth:
        jwt:
          serviceAccountRef:
            name: external-secrets
            namespace: external-secrets
```

- ESO installs CRDs + controller + ClusterSecretStore — all tracked in Git as one unit
- Platform-level component — GitOps ownership is cleaner than Terraform
- `selfHeal` ensures secrets pipeline never breaks silently
- Terraform would need to manage both the Helm release AND the ClusterSecretStore CR — messy

---

### 10. Cluster-wide RBAC and Namespaces

#### Deployment Methods

| # | Method | Tool |
|---|---|---|
| 1 | **Harness GitOps (Argo CD + Kustomize)** | GitOps |
| 2 | **Terraform Kubernetes provider** | Terraform |
| 3 | **kubectl apply** | kubectl |
| 4 | **Harness CD Pipeline** | Harness Agent |
| 5 | **Ansible** | Ansible |
| 6 | **Crossplane** | Crossplane |

#### Why Harness GitOps Wins for RBAC and Namespaces

```yaml
# Git repo: cluster-config/namespaces/production.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: production
  labels:
    environment: production
    team: platform
---
# cluster-config/rbac/dev-role.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: dev-access
  namespace: production
subjects:
  - kind: Group
    name: developers
    apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: edit
  apiGroup: rbac.authorization.k8s.io
```

- RBAC changes are **security-sensitive** — Git PR process enforces peer review
- `selfHeal` prevents privilege escalation — if someone adds a rolebinding manually, Argo reverts it
- Terraform Kubernetes provider works but adds to state complexity
- kubectl is manual and leaves no structured audit trail
- Ansible is config management, not the right tool for Kubernetes RBAC

---

## LAYER 3 — HARNESS CD PIPELINES

---

### 11. Application Deployments

#### Deployment Methods

| # | Method | Tool |
|---|---|---|
| 1 | **Harness CD Pipeline** | Harness Agent |
| 2 | **Harness GitOps** | GitOps |
| 3 | **Argo CD standalone** | GitOps |
| 4 | **Helm CLI in CI/CD** | Helm + Jenkins/GitHub Actions |
| 5 | **kubectl in CI/CD** | kubectl + CI |
| 6 | **Spinnaker** | Spinnaker |
| 7 | **Flux CD** | Flux |
| 8 | **Terraform Helm provider** | Terraform |

#### Why Harness CD Pipeline Wins for App Deployments

```yaml
# Harness Pipeline YAML
pipeline:
  name: Deploy My App
  stages:
    - stage:
        name: Deploy to Dev
        type: Deployment
        spec:
          deploymentType: Kubernetes
          execution:
            steps:
              - step:
                  type: K8sRollingDeploy
                  name: Rolling Deploy
    - stage:
        name: Approval
        type: Approval
        spec:
          execution:
            steps:
              - step:
                  type: HarnessApproval
                  name: Prod Approval
                  spec:
                    approvers:
                      userGroups: ["platform-team"]
    - stage:
        name: Deploy to Production
        type: Deployment
        spec:
          deploymentType: Kubernetes
          execution:
            steps:
              - step:
                  type: K8sCanaryDeploy
                  name: Canary 20%
```

- **Approval gates** — GitOps auto-syncs cannot pause for human approval
- **Canary/Blue-Green** built-in deployment strategies
- **Environment promotion** — dev → staging → prod in one pipeline
- **Rollback button** — one click rollback in UI with no Git revert needed
- **RBAC** — devs trigger pipelines, only ops can approve prod
- **Notifications** — Slack/email/PagerDuty on success or failure
- GitOps is eventually consistent — not suitable when you need to know "did my deploy succeed right now?"
- Helm in CI is stateless — no rollback, no approval gates, no environment tracking
- Terraform is too slow for frequent app deployments

---

### 12. Environment Promotion (dev → staging → prod)

#### Deployment Methods

| # | Method | Tool |
|---|---|---|
| 1 | **Harness CD Multi-stage Pipeline** | Harness Agent |
| 2 | **GitOps with environment branches** | GitOps |
| 3 | **GitOps with Kustomize overlays** | GitOps |
| 4 | **ArgoCD ApplicationSets** | Argo CD |
| 5 | **Jenkins Pipeline** | Jenkins |
| 6 | **GitHub Actions workflow** | GitHub Actions |
| 7 | **Spinnaker** | Spinnaker |

#### Why Harness CD Wins for Environment Promotion

```yaml
# values-dev.yaml → values-staging.yaml → values-prod.yaml
# Harness handles overrides per environment automatically

# Environment-specific overrides in Harness
environments:
  dev:
    replicas: 1
    image_tag: latest
  staging:
    replicas: 2
    image_tag: "1.2.3"
  prod:
    replicas: 5
    image_tag: "1.2.3"
    approval_required: true
```

- Single pipeline definition promotes across all environments
- Approval gate between staging and prod is native
- GitOps branches per environment creates merge conflicts and drift between branches
- Jenkins/GitHub Actions require custom scripting for approvals and notifications
- Harness tracks which version is in which environment — visible in the UI

---

### 13. Canary / Blue-Green Deployments

#### Deployment Methods

| # | Method | Tool |
|---|---|---|
| 1 | **Harness CD Pipeline (built-in strategy)** | Harness Agent |
| 2 | **Argo Rollouts** | Argo |
| 3 | **Flagger** | Flagger + Prometheus |
| 4 | **AWS CodeDeploy** | AWS |
| 5 | **Manual kubectl weight patching** | kubectl |
| 6 | **Istio traffic splitting** | Service Mesh |
| 7 | **NGINX Ingress canary annotations** | Ingress |

#### Why Harness CD Wins for Canary/Blue-Green

```yaml
# Harness Canary — no extra tooling needed
steps:
  - step:
      type: K8sCanaryDeploy
      spec:
        instances:
          type: Count
          spec:
            count: 2          # deploy 2 pods as canary first
  - step:
      type: K8sCanaryDelete   # clean up canary on success
  - step:
      type: K8sRollingDeploy  # full rollout
```

- **No extra components needed** — Argo Rollouts and Flagger require additional CRDs and controllers
- **UI visibility** — see canary traffic split in Harness dashboard
- **Automatic rollback** on failure metrics (integrates with Prometheus, Datadog, CloudWatch)
- **Integrated approval** — pause canary at 20%, get approval, then continue to 100%
- Manual kubectl patching is error-prone and not reproducible

---

## Decision Matrix — Which Tool for Which Resource

| Resource | Terraform | Helm CLI | Harness GitOps | Harness CD | Winner |
|---|---|---|---|---|---|
| EKS Cluster | ✅ Best | ❌ | ❌ | ❌ | **Terraform** |
| VPC / Subnets | ✅ Best | ❌ | ❌ | ❌ | **Terraform** |
| IAM / IRSA Roles | ✅ Best | ❌ | ❌ | ❌ | **Terraform** |
| AWS LB Controller | ✅ Best | ⚠️ | ⚠️ | ⚠️ | **Terraform** |
| EBS CSI Driver | ✅ Best | ⚠️ | ⚠️ | ⚠️ | **Terraform** |
| NGINX Ingress | ⚠️ | ⚠️ | ✅ Best | ⚠️ | **GitOps** |
| cert-manager | ⚠️ | ⚠️ | ✅ Best | ⚠️ | **GitOps** |
| TargetGroup Binding CRDs | ⚠️ | ⚠️ | ✅ Best | ⚠️ | **GitOps** |
| External Secrets Operator | ⚠️ | ⚠️ | ✅ Best | ⚠️ | **GitOps** |
| Cluster RBAC / Namespaces | ⚠️ | ❌ | ✅ Best | ⚠️ | **GitOps** |
| App Deployments | ❌ | ⚠️ | ⚠️ | ✅ Best | **Harness CD** |
| Environment Promotion | ❌ | ❌ | ⚠️ | ✅ Best | **Harness CD** |
| Canary / Blue-Green | ❌ | ❌ | ⚠️ | ✅ Best | **Harness CD** |

**Legend:** ✅ Best fit &nbsp;|&nbsp; ⚠️ Works but not ideal &nbsp;|&nbsp; ❌ Wrong tool

---

## Key Decision Rules

```
Use TERRAFORM when:
  → Resource is AWS infrastructure (cluster, VPC, IAM, subnets)
  → Resource needs dynamic values from AWS (ARNs, OIDC URLs)
  → Resource is created once and rarely changed
  → You need depends_on between AWS and Kubernetes resources

Use HARNESS GITOPS when:
  → Resource is a cluster-wide platform component
  → Resource includes CRDs
  → You want drift prevention (selfHeal)
  → Changes should go through Git PR review
  → Resource is updated occasionally but not continuously

Use HARNESS CD PIPELINE when:
  → Deploying application workloads
  → You need approval gates between environments
  → You need canary or blue-green strategies
  → You need one-click rollback
  → You need audit trail of who approved what deployment
  → Promoting across dev → staging → production
```

---

## Bootstrap Order

```
1. terraform apply          → VPC + EKS + IAM roles
2. terraform apply          → AWS LB Controller + EBS CSI (Helm via Terraform)
3. helm install argo-cd     → Bootstrap Argo CD (one-time only)
4. kubectl apply            → Register Harness GitOps Agent + Argo CD App-of-Apps
5. GitOps auto-sync         → NGINX, cert-manager, ESO, CRDs, RBAC, Namespaces
6. Harness CD pipeline      → Application deployments begin
```

> Step 3 is the only manual step. Everything else is automated and tracked.
