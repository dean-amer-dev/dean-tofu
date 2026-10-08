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
    prefix = "k3s/infra/prod/llm-metal-agent"
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

variable "namespace" {
  description = "Namespace the metal agent watches (--namespace)"
  type        = string
  default     = "llm"
}

# Least-privilege identity for the LLMKube Metal agent running natively on the Mac mini.
# Mirrors deployment/macos/metal-agent-rbac.yaml in defilantech/LLMKube v0.10.1.
resource "kubectl_manifest" "service_account" {
  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "ServiceAccount"
    metadata   = { name = "llmkube-metal-agent", namespace = var.namespace }
  })
}

resource "kubectl_manifest" "role" {
  yaml_body = yamlencode({
    apiVersion = "rbac.authorization.k8s.io/v1"
    kind       = "Role"
    metadata   = { name = "llmkube-metal-agent", namespace = var.namespace }
    rules = [
      { apiGroups = ["inference.llmkube.dev"], resources = ["inferenceservices"], verbs = ["get", "list"] },
      { apiGroups = ["inference.llmkube.dev"], resources = ["inferenceservices/status"], verbs = ["update"] },
      { apiGroups = ["inference.llmkube.dev"], resources = ["models"], verbs = ["get"] },
      { apiGroups = [""], resources = ["services"], verbs = ["get", "list", "create", "update", "delete"] },
      { apiGroups = ["discovery.k8s.io"], resources = ["endpointslices"], verbs = ["get", "create", "update", "delete"] },
      { apiGroups = [""], resources = ["endpoints"], verbs = ["get", "delete"] },
      { apiGroups = [""], resources = ["events"], verbs = ["create", "patch"] },
      { apiGroups = [""], resources = ["secrets"], verbs = ["get"] },
    ]
  })
}

resource "kubectl_manifest" "role_binding" {
  depends_on = [kubectl_manifest.role, kubectl_manifest.service_account]
  yaml_body = yamlencode({
    apiVersion = "rbac.authorization.k8s.io/v1"
    kind       = "RoleBinding"
    metadata   = { name = "llmkube-metal-agent", namespace = var.namespace }
    roleRef    = { apiGroup = "rbac.authorization.k8s.io", kind = "Role", name = "llmkube-metal-agent" }
    subjects   = [{ kind = "ServiceAccount", name = "llmkube-metal-agent", namespace = var.namespace }]
  })
}

# Non-expiring ServiceAccount token (`kubectl create token` expires and would need re-minting).
# The control plane fills in .data.token and .data.ca.crt.
resource "kubectl_manifest" "token" {
  depends_on = [kubectl_manifest.service_account]
  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "Secret"
    metadata = {
      name        = "llmkube-metal-agent-token"
      namespace   = var.namespace
      annotations = { "kubernetes.io/service-account.name" = "llmkube-metal-agent" }
    }
    type = "kubernetes.io/service-account-token"
  })
  ignore_fields = ["data"]
}
