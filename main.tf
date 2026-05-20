
resource "harness_platform_delegatetoken" "project_level" {
  name       = "project-delegate-token"
  account_id = "0f2e5dEIT1uHtaREhdbDEQ"
  org_id     = "default"
  project_id = "HelloWorld"
}


# Step 2: Deploy Delegate into Kubernetes
module "harness_delegate" {
  source  = "harness/harness-delegate/kubernetes"
  version = "0.2.4"

  account_id       = "0f2e5dEIT1uHtaREhdbDEQ"
  delegate_token   = harness_platform_delegatetoken.project_level.value
  delegate_name    = "k8s-delegate"
  manager_endpoint = "https://app.harness.io"
  namespace        = "harness-delegate-ng"
  delegate_image   = "harness/delegate:24.07.83605"

  values = "replicaCount: 1"

  depends_on = [harness_platform_delegatetoken.project_level]
}

# Step 3: Register Kubernetes Connector using the Delegate
resource "harness_platform_connector_kubernetes" "k8s_connector" {
  name       = "K8s-Cluster-Connector"
  identifier = "k8sclusterconnector"
  org_id     = "default"
  project_id = "HelloWorld"

  inherit_from_delegate {
    delegate_selectors = ["k8s-delegate"]
  }

  depends_on = [module.harness_delegate]
}
