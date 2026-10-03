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
    prefix = "k3s/infra/prod/runners"
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

resource "kubectl_manifest" "controller" {
  yaml_body = file("${path.module}/controller.yaml")
}

# The scale set's listener sits crash-looping (harmlessly, it self-heals) until the ExternalSecret
# inside this Application has produced the GitHub App Secret - same eager-creation pattern as
# k3s/app-of-apps/, no wait mechanism.
resource "kubectl_manifest" "scale_set" {
  depends_on = [kubectl_manifest.controller]
  yaml_body  = file("${path.module}/scale-set.yaml")
}
