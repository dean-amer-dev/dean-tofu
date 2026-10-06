terraform {
  required_version = ">= 1.6.0"

  required_providers {
    kubectl = {
      source  = "alekc/kubectl"
      version = "~> 2.1"
    }
    bitwarden-secrets = {
      source  = "bitwarden/bitwarden-secrets"
      version = "~> 1.0"
    }
  }

  backend "gcs" {
    bucket = "amerenda-dean-tofu-state"
    prefix = "k3s/apps/prod/mem0"
  }
}

provider "kubectl" {
  config_path      = var.kubeconfig_path
  load_config_file = true
}

# Auth via BW_ACCESS_TOKEN / BW_ORGANIZATION_ID env vars - never committed to this repo.
provider "bitwarden-secrets" {
  api_url      = "https://api.bitwarden.com"
  identity_url = "https://identity.bitwarden.com"
}

variable "kubeconfig_path" {
  description = "Path to the dean kubeconfig (points at the VIP, 10.100.20.161)"
  type        = string
  default     = "~/.kube/dean.yaml"
}

resource "kubectl_manifest" "namespace" {
  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "Namespace"
    metadata   = { name = "mem0" }
  })
}

# mem0's vectors, users, API keys and request log all live in this one database (the server's
# APP_DB_NAME and POSTGRES_DB point at it). The old mini database's BWS secret
# mem0-postgres-password stays untouched until the mini is cleaned up, hence the explicit bws_key.
module "db" {
  source        = "../../../../modules/app-postgres"
  depends_on    = [kubectl_manifest.namespace]
  app_name      = "mem0"
  app_namespace = "mem0"
  bws_key       = "mem0-k3s-postgres-password"
  extensions    = ["vector"]
}

resource "kubectl_manifest" "application" {
  depends_on = [module.db]
  yaml_body  = file("${path.module}/application.yaml")
}
