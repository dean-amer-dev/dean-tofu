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
    prefix = "k3s/infra/postgres"
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

resource "kubectl_manifest" "operator" {
  yaml_body = file("${path.module}/operator.yaml")
}

# The cluster + backup CronJob Application is created eagerly; its CNPG resources retry until the
# operator's CRDs exist (SkipDryRunOnMissingResource + retry), same pattern as k3s/infra/mongodb/.
resource "kubectl_manifest" "cluster" {
  depends_on = [kubectl_manifest.operator]
  yaml_body  = file("${path.module}/cluster.yaml")
}
