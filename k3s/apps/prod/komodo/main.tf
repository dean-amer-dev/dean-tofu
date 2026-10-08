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
    prefix = "k3s/apps/prod/komodo"
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

resource "kubectl_manifest" "application" {
  yaml_body = file("${path.module}/application.yaml")
}

# The MongoDB replica set for Komodo lives with Komodo, not the operator (infra/prod/mongodb). Created
# eagerly; its MongoDBCommunity resource retries until the operator's CRDs exist
# (SkipDryRunOnMissingResource + retry), same pattern as k3s/app-of-apps/.
resource "kubectl_manifest" "komodo_replica_set" {
  yaml_body = file("${path.module}/komodo-replica-set.yaml")
}
