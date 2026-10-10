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
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  backend "gcs" {
    bucket = "amerenda-dean-tofu-state"
    prefix = "k3s/apps/prod/phoenix"
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

# Copy-paste slip from the openwebui app: this address once held the openwebui Namespace. Forget it
# without deleting the namespace.
removed {
  from = kubectl_manifest.namespace
  lifecycle {
    destroy = false
  }
}

resource "kubectl_manifest" "phoenix_namespace" {
  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "Namespace"
    metadata   = { name = "phoenix" }
  })
}

module "db" {
  source        = "../../../../modules/app-postgres"
  depends_on    = [kubectl_manifest.phoenix_namespace]
  app_name      = "phoenix"
  app_namespace = "phoenix"
  bws_key       = "phoenix-k3s-postgres-password"
}

locals {
  bws_project_id = "6353f589-39c0-45f2-9e9c-b36f00e0c282"
  generated_secrets = {
    "phoenix-secret-key"     = "Phoenix PHOENIX_SECRET (token signing)"
    "phoenix-admin-secret"   = "Phoenix PHOENIX_ADMIN_SECRET (system API key signing)"
    "phoenix-admin-password" = "Phoenix initial admin password"
  }
}

resource "random_password" "generated" {
  for_each = local.generated_secrets
  length   = 48
  special  = false
}

resource "bitwarden-secrets_secret" "generated" {
  for_each   = local.generated_secrets
  key        = each.key
  value      = random_password.generated[each.key].result
  note       = each.value
  project_id = local.bws_project_id
}

resource "kubectl_manifest" "application" {
  depends_on = [module.db, bitwarden-secrets_secret.generated]
  yaml_body  = file("${path.module}/application.yaml")
}
