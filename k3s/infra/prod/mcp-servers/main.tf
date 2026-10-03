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
    prefix = "k3s/infra/prod/mcp-servers"
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

resource "kubectl_manifest" "applicationset" {
  yaml_body = file("${path.module}/applicationset.yaml")
}

# litellm shares this state so one apply covers a server and its litellm entry
resource "kubectl_manifest" "litellm" {
  yaml_body = file("${path.module}/litellm-application.yaml")
}
