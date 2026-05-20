variable "harness_account_id" {
  type      = string
  sensitive = true
}

variable "harness_api_key" {
  description = "Harness Platform API key (Service Account token)"
  type        = string
  sensitive   = true
}

variable "manager_endpoint" {
  type    = string
  default = "https://app.harness.io"
}