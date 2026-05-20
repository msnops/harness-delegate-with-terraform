# ── Step 1: Create a Harness Project (optional, skip if project exists) ──
resource "harness_platform_project" "project" {
  name       = "my-project"
  identifier = "myproject"
  org_id     = "default"
}

# ── Step 2: Create the Delegate Token in Harness ──
resource "harness_platform_delegate_token" "delegate_token" {
  name       = "k8s-delegate-token"
  account_id = var.harness_account_id
  org_id     = "default"
  project_id = harness_platform_project.project.identifier
}

# ── Step 3: Deploy the Delegate into Kubernetes ──
module "harness_delegate" {
  source  = "harness/harness-delegate/kubernetes"
  version = "0.2.4"

  account_id       = var.harness_account_id
  delegate_token   = harness_platform_delegate_token.delegate_token.value
  delegate_name    = "k8s-delegate"
  manager_endpoint = var.manager_endpoint
  namespace        = "harness-delegate-ng"
  delegate_replicas = 2

  depends_on = [harness_platform_delegate_token.delegate_token]
}

# ── Step 4: Wait for the Delegate to become healthy ──
resource "time_sleep" "wait_for_delegate" {
  create_duration = "60s"
  depends_on      = [module.harness_delegate]
}

# ── Step 5: Create a Kubernetes Connector using the Delegate ──
resource "harness_platform_connector_kubernetes" "k8s_connector" {
  name       = "K8s-Cluster-Connector"
  identifier = "k8sclusterconnector"
  org_id     = "default"
  project_id = harness_platform_project.project.identifier

  inherit_from_delegate {
    delegate_selectors = ["k8s-delegate"]
  }

  depends_on = [time_sleep.wait_for_delegate]
}

# ── Step 6: Create an Environment ──
resource "harness_platform_environment" "env" {
  name       = "production"
  identifier = "production"
  org_id     = "default"
  project_id = harness_platform_project.project.identifier
  type       = "Production"
}

# ── Step 7: Create Infrastructure Definition ──
resource "harness_platform_infrastructure" "infra" {
  name            = "k8s-infra"
  identifier      = "k8sinfra"
  org_id          = "default"
  project_id      = harness_platform_project.project.identifier
  env_id          = harness_platform_environment.env.identifier
  type            = "KubernetesDirect"
  deployment_type = "Kubernetes"

  yaml = <<-EOT
    infrastructureDefinition:
      name: k8s-infra
      identifier: k8sinfra
      orgIdentifier: default
      projectIdentifier: ${harness_platform_project.project.identifier}
      environmentRef: ${harness_platform_environment.env.identifier}
      deploymentType: Kubernetes
      type: KubernetesDirect
      spec:
        connectorRef: ${harness_platform_connector_kubernetes.k8s_connector.identifier}
        namespace: default
        releaseName: release-<+INFRA_KEY>
  EOT
}