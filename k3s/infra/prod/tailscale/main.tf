terraform {
  required_version = ">= 1.6.0"

  required_providers {
    kubectl = {
      source  = "alekc/kubectl"
      version = "~> 2.1"
    }
    tailscale = {
      source  = "tailscale/tailscale"
      version = "~> 0.29"
    }
    bitwarden-secrets = {
      source  = "bitwarden/bitwarden-secrets"
      version = "~> 1.0"
    }
  }

  backend "gcs" {
    bucket = "amerenda-dean-tofu-state"
    prefix = "k3s/infra/prod/tailscale"
  }
}

provider "kubectl" {
  config_path      = var.kubeconfig_path
  load_config_file = true
}

# Auth via BW_ACCESS_TOKEN / BW_ORGANIZATION_ID env vars (a Bitwarden Secrets
# Manager machine account token) - never committed to this repo. api_url/
# identity_url are the standard Bitwarden cloud endpoints, not per-org secrets.
provider "bitwarden-secrets" {
  api_url      = "https://api.bitwarden.com"
  identity_url = "https://identity.bitwarden.com"
}

data "bitwarden-secrets_secret" "tailscale_oauth_client_id" {
  id = "6706508d-3088-464e-ac03-b4d300ba97d3" # tailscale-dean-oauth-client-id
}

data "bitwarden-secrets_secret" "tailscale_oauth_client_secret" {
  id = "385c7875-6af2-4096-9cea-b4d300babfcd" # tailscale-dean-oauth-client-secret
}

provider "tailscale" {
  oauth_client_id     = data.bitwarden-secrets_secret.tailscale_oauth_client_id.value
  oauth_client_secret = data.bitwarden-secrets_secret.tailscale_oauth_client_secret.value
}

variable "kubeconfig_path" {
  description = "Path to the dean kubeconfig (points at the VIP, 10.100.20.161)"
  type        = string
  default     = "~/.kube/dean.yaml"
}

resource "kubectl_manifest" "application" {
  yaml_body = file("${path.module}/application.yaml")
}

resource "tailscale_acl" "this" {
  acl                        = file("${path.module}/policy.hujson")
  overwrite_existing_content = true
  reset_acl_on_destroy       = false
}
