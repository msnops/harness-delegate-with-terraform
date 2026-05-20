provider "harness" {
  endpoint        = var.manager_endpoint       # https://app.harness.io
  account_id      = var.harness_account_id
  platform_api_key = var.harness_api_key       # Harness API key (not delegate token)
}

provider "helm" {
  kubernetes {
    config_path = "~/.kube/config"
  }
}

provider "kubernetes" {
  config_path = "~/.kube/config"
}