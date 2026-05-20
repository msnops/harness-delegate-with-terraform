terraform {
  required_providers {
    harness = {
      source  = "harness/harness"
      version = "~> 0.30"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
  }
}