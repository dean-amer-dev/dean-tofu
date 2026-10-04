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
    prefix = "k3s/apps/prod/tdarr"
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

locals {
  flow_files = ["flow.json", "libraries.json", "decide-crop-codec-audio.js", "decide-hdr-audio-only.js", "sync.py"]
  flow_hash  = substr(sha256(join("", [for f in local.flow_files : file("${path.module}/flow/${f}")])), 0, 8)
}

resource "kubectl_manifest" "flow_configmap" {
  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "ConfigMap"
    metadata   = { name = "tdarr-flow", namespace = "tdarr" }
    data       = { for f in local.flow_files : f => file("${path.module}/flow/${f}") }
  })
  depends_on = [kubectl_manifest.application]
}

# Named by content hash: a flow/library change creates a new Job, which re-runs the
# idempotent sync. The old Job is deleted by tofu on replace.
resource "kubectl_manifest" "flow_sync" {
  yaml_body = yamlencode({
    apiVersion = "batch/v1"
    kind       = "Job"
    metadata   = { name = "tdarr-flow-sync-${local.flow_hash}", namespace = "tdarr" }
    spec = {
      backoffLimit = 3
      template = {
        spec = {
          restartPolicy   = "OnFailure"
          securityContext = { runAsNonRoot = true, runAsUser = 65534 }
          containers = [{
            name    = "sync"
            image   = "python:3.12-alpine"
            command = ["python3", "/flow/sync.py"]
            env = [
              { name = "FLOW_DIR", value = "/flow" },
              { name = "TDARR_URL", value = "http://tdarr-server.tdarr.svc.cluster.local:8265" },
            ]
            volumeMounts = [{ name = "flow", mountPath = "/flow" }]
            resources = {
              requests = { cpu = "25m", memory = "32Mi" }
              limits   = { cpu = "100m", memory = "128Mi" }
            }
          }]
          volumes = [{ name = "flow", configMap = { name = "tdarr-flow" } }]
        }
      }
    }
  })
  wait_for {
    field {
      key   = "status.succeeded"
      value = "1"
    }
  }
  depends_on = [kubectl_manifest.flow_configmap]
}
