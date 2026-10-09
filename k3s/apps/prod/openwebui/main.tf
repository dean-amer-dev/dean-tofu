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
    prefix = "k3s/apps/prod/openwebui"
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
    metadata   = { name = "openwebui" }
  })
}

# OpenWebUI's users, chats, presets and tool-server config live in this one database. The
# restore from the legacy mini dump happens in the Deployment's init containers.
module "db" {
  source        = "../../../../modules/app-postgres"
  depends_on    = [kubectl_manifest.namespace]
  app_name      = "openwebui"
  app_namespace = "openwebui"
  bws_key       = "openwebui-k3s-postgres-password"
}

resource "kubectl_manifest" "application" {
  depends_on = [module.db]
  yaml_body  = file("${path.module}/application.yaml")
}
