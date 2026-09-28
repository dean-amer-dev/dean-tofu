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
    prefix = "k3s/infra"
  }
}

provider "kubectl" {
  config_path      = var.kubeconfig_path
  load_config_file = true
}

variable "kubeconfig_path" {
  description = "Path to the gmktec kubeconfig (points at the VIP, 10.100.20.161)"
  type        = string
  default     = "~/.kube/gmktec.yaml"
}

# Each infra-tier app is its own child module, in its own folder - not one shared ApplicationSet
# spanning multiple apps (per Alex, 2026-09-28). One `tofu apply` at this root still creates/
# updates every infra app at once; they're just organized and reviewed independently.
module "tailscale" {
  source = "./tailscale"
}
