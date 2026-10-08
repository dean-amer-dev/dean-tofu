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
    prefix = "k3s/apps/prod/zigbee2mqtt"
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

# One-time migration seed from the Mac Mini. Directory with z2m-data/ and external_extensions/
# (never committed). Set while migrating so the init container can populate an empty PVC; unset
# afterwards to delete the Secret. The init container only copies when database.db is absent.
variable "seed_dir" {
  description = "Local directory holding the Mac Mini z2m-data/ and external_extensions/ state, or empty"
  type        = string
  default     = ""
}

resource "kubectl_manifest" "namespace" {
  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "Namespace"
    metadata   = { name = "zigbee2mqtt" }
  })
}

# Code, not state: smart-lighting.js and the SLZB keepalive proxy. Reloader rolls the pod on change.
resource "kubectl_manifest" "files" {
  depends_on = [kubectl_manifest.namespace]
  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "ConfigMap"
    metadata   = { name = "zigbee2mqtt-files", namespace = "zigbee2mqtt" }
    data = {
      "smart-lighting.js" = file("${path.module}/files/smart-lighting.js")
      "slzb-proxy.py"     = file("${path.module}/files/slzb-proxy.py")
    }
  })
}

locals {
  seed_files = var.seed_dir == "" ? {} : {
    "configuration.yaml"      = "${var.seed_dir}/z2m-data/configuration.yaml"
    "coordinator_backup.json" = "${var.seed_dir}/z2m-data/coordinator_backup.json"
    "database.db"             = "${var.seed_dir}/z2m-data/database.db"
    "state.json"              = "${var.seed_dir}/z2m-data/state.json"
    "sl-cache.json"           = "${var.seed_dir}/external_extensions/sl-cache.json"
    "sl-pushed-hash.json"     = "${var.seed_dir}/external_extensions/sl-pushed-hash.json"
  }
}

resource "kubectl_manifest" "seed" {
  count            = var.seed_dir == "" ? 0 : 1
  depends_on       = [kubectl_manifest.namespace]
  sensitive_fields = ["data"]
  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "Secret"
    metadata   = { name = "zigbee2mqtt-seed", namespace = "zigbee2mqtt" }
    type       = "Opaque"
    data       = { for k, p in local.seed_files : k => filebase64(p) }
  })
}

resource "kubectl_manifest" "application" {
  depends_on = [kubectl_manifest.files]
  yaml_body  = file("${path.module}/application.yaml")
}
