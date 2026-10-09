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
    prefix = "k3s/infra/prod/llm-models"
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

locals {
  namespace         = "llm"
  metal_model_store = "/Users/alex/.omlx/models"
  cuda_image        = "ghcr.io/dean-amer-dev/murderbot-llm@sha256:6ee1e235b1361f2b00eec09f72f1dd5157f01c917cb36ad35c50238f4ab2d222"

  pvc = {
    apiVersion = "v1"
    kind       = "PersistentVolumeClaim"
    metadata = {
      name        = "llm-models"
      namespace   = local.namespace
      annotations = { "argocd.argoproj.io/sync-options" = "Prune=false,Delete=false" }
    }
    spec = {
      accessModes      = ["ReadWriteOnce"]
      storageClassName = "murderbot-local"
      resources        = { requests = { storage = "200Gi" } }
    }
  }

  cuda_resources = flatten([
    for name, m in local.cuda_models : [
      {
        apiVersion = "inference.llmkube.dev/v1alpha1"
        kind       = "Model"
        metadata   = { name = m.model_name, namespace = local.namespace }
        spec = {
          source        = "https://huggingface.co/${m.repo}/resolve/${m.revision}/${m.file}"
          sha256        = m.sha256
          format        = "custom"
          quantization  = "nvfp4"
          refreshPolicy = "IfNotPresent"
          hardware = {
            accelerator = "cuda"
            gpu         = { enabled = true, count = 1, vendor = "nvidia" }
          }
        }
      },
      {
        apiVersion = "inference.llmkube.dev/v1alpha1"
        kind       = "InferenceService"
        metadata   = { name = name, namespace = local.namespace }
        spec = {
          modelRef         = m.model_name
          runtime          = "generic"
          image            = local.cuda_image
          replicas         = m.replicas
          containerPort    = 8080
          endpoint         = { port = 8080, type = "ClusterIP" }
          runtimeClassName = "nvidia"
          nodeSelector     = { "gpu-worker" = "true" }
          tolerations      = [{ key = "gpu-worker", operator = "Equal", value = "true", effect = "NoSchedule" }]
          env = [
            { name = "MODEL_URL", value = "https://huggingface.co/${m.repo}/resolve/${m.revision}/${m.file}" },
            { name = "MODEL_SHA256", value = m.sha256 },
            { name = "MODEL_FILE", value = "/models/${m.cache_dir}/${substr(m.revision, 0, 7)}/${m.file}" },
            { name = "MODEL_REPO", value = m.repo },
            { name = "MODEL_REVISION", value = m.revision },
          ]
          extraVolumes      = [{ name = "models", persistentVolumeClaim = { claimName = "llm-models" } }]
          extraVolumeMounts = [{ name = "models", mountPath = "/models" }]
          probeOverrides = {
            startup   = { tcpSocket = { port = 8080 }, periodSeconds = 10, timeoutSeconds = 5, failureThreshold = 360 }
            readiness = { httpGet = { path = "/health", port = 8080 }, periodSeconds = 10, timeoutSeconds = 5, failureThreshold = 3 }
          }
          resources = { gpu = 1, cpu = "8", memory = "28Gi" }
          args = [
            "$(MODEL_FILE)",
            "--host", "0.0.0.0",
            "--port", "8080",
            "--model-id", m.model_id,
            "--kv-dtype", "nvfp4",
            "--max-context", "180224",
            "--spec", "mtp",
            "--draft-tokens", "3",
            "--max-concurrency", "1",
            "--device-state-slots", "0",
          ]
        }
      },
    ]
  ])

  metal_resources = flatten([
    for name, m in local.metal_models : [
      {
        apiVersion = "inference.llmkube.dev/v1alpha1"
        kind       = "Model"
        metadata   = { name = m.model_name, namespace = local.namespace }
        spec = {
          source   = "${local.metal_model_store}/${m.repo}"
          format   = "mlx"
          hardware = { accelerator = "metal" }
        }
      },
      {
        apiVersion = "inference.llmkube.dev/v1alpha1"
        kind       = "InferenceService"
        metadata   = { name = name, namespace = local.namespace }
        spec       = { modelRef = m.model_name, runtime = "omlx", replicas = m.replicas }
      },
    ]
  ])

  # Backends forward the upstream model id via "external" URLs: inferenceServiceRef backends
  # do not rewrite the model name (dean-tofu #82).
  router_backends = concat(
    [for name, m in local.cuda_models : {
      name        = name
      displayName = m.model_id
      resolution  = "service"
      tier        = "local"
      external    = { provider = "openai", url = "http://${name}.${local.namespace}.svc.cluster.local:8080", model = m.model_id }
    }],
    [for name, m in local.metal_models : {
      name        = name
      displayName = basename(m.repo)
      resolution  = "service"
      tier        = "local"
      external    = { provider = "openai", url = "http://${name}.${local.namespace}.svc.cluster.local:8080", model = basename(m.repo) }
    }],
  )

  router = {
    apiVersion = "inference.llmkube.dev/v1alpha1"
    kind       = "ModelRouter"
    metadata   = { name = "llm", namespace = local.namespace }
    spec = {
      dataPlane            = "Proxy"
      defaultRouteStrategy = "BackendNameMatch"
      proxy                = { replicas = 2 }
      endpoint             = { type = "ClusterIP", port = 8080, path = "/v1/chat/completions" }
      backends             = local.router_backends
    }
  }

  application = {
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata   = { name = "llm-models", namespace = "argocd" }
    spec = {
      project = "default"
      source = {
        repoURL        = "https://bedag.github.io/helm-charts/"
        chart          = "raw"
        targetRevision = "2.0.2"
        helm = {
          values = yamlencode({
            resources = concat([local.pvc], local.cuda_resources, local.metal_resources, [local.router])
          })
        }
      }
      ignoreDifferences = [{
        group        = "inference.llmkube.dev"
        kind         = "InferenceService"
        jsonPointers = ["/spec/replicas"]
      }]
      destination = { server = "https://kubernetes.default.svc", namespace = local.namespace }
      syncPolicy = {
        automated   = { prune = true, selfHeal = true }
        syncOptions = ["CreateNamespace=true", "ServerSideApply=true", "RespectIgnoreDifferences=true"]
        retry       = { limit = 10, backoff = { duration = "10s", factor = 2, maxDuration = "5m" } }
      }
    }
  }
}

resource "kubectl_manifest" "application" {
  yaml_body = yamlencode(local.application)
}
