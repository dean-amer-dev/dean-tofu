terraform {
  required_version = ">= 1.6.0"

  required_providers {
    kubectl = {
      source  = "alekc/kubectl"
      version = "~> 2.1"
    }
  }

  backend "gcs" {
    bucket = "amerenda-dean-tofu-state"
    prefix = "k3s/apps/prod/argo-workflows"
  }
}

provider "kubectl" {
  config_path      = var.kubeconfig_path
  load_config_file = true
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
    metadata   = { name = "argo-workflows" }
  })
}

resource "kubectl_manifest" "application" {
  depends_on = [kubectl_manifest.namespace]
  yaml_body  = file("${path.module}/application.yaml")
}
