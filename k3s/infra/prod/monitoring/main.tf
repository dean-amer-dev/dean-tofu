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
    prefix = "k3s/infra/prod/monitoring"
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
    metadata   = { name = "monitoring" }
  })
}

# Grafana's database. The credential Secret grafana-postgres (uri key) lands in the monitoring namespace.
module "db" {
  source        = "../../../../modules/app-postgres"
  depends_on    = [kubectl_manifest.namespace]
  app_name      = "grafana"
  app_namespace = "monitoring"
  bws_key       = "grafana-k3s-postgres-password"
}

# Supporting resources (ExternalSecrets, later probes/scrapes) through the raw chart.
resource "kubectl_manifest" "config" {
  depends_on = [kubectl_manifest.namespace]
  yaml_body  = file("${path.module}/config.yaml")
}

resource "kubectl_manifest" "application" {
  depends_on = [module.db, kubectl_manifest.config]
  yaml_body  = file("${path.module}/application.yaml")
}

resource "kubectl_manifest" "blackbox" {
  depends_on = [kubectl_manifest.application]
  yaml_body  = file("${path.module}/blackbox.yaml")
}

resource "kubectl_manifest" "scrapes" {
  depends_on = [kubectl_manifest.blackbox]
  yaml_body  = file("${path.module}/scrapes.yaml")
}

resource "kubectl_manifest" "dashboards" {
  for_each   = fileset("${path.module}/dashboards", "*.yaml")
  depends_on = [kubectl_manifest.application]
  yaml_body  = file("${path.module}/dashboards/${each.value}")
}
