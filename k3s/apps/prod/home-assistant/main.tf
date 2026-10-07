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
    prefix = "k3s/apps/prod/home-assistant"
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
    metadata   = { name = "home-assistant" }
  })
}

# Recorder (history) database on the shared CNPG cluster. Creates the BWS secret
# home-assistant-postgres-password and the home-assistant-postgres Secret (key "uri") in the namespace.
module "db" {
  source        = "../../../../modules/app-postgres"
  depends_on    = [kubectl_manifest.namespace]
  app_name      = "home-assistant"
  app_namespace = "home-assistant"
}

resource "kubectl_manifest" "application" {
  depends_on = [module.db]
  yaml_body  = file("${path.module}/application.yaml")
}

# Temporary Phase 3 check, removed from the code once the recorder schema is confirmed.
resource "kubectl_manifest" "verify" {
  depends_on = [kubectl_manifest.application]
  yaml_body  = file("${path.module}/verify.yaml")
}
