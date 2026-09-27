terraform {
  required_version = ">= 1.6.0"

  required_providers {
    kubectl = {
      source  = "alekc/kubectl"
      version = "~> 2.1"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }

  # Native GCS backend (not the s3 backend type against GCS's S3-interop endpoint - app-factory's
  # main.tf documents that HMAC keys fail there: AWS SDK Go v2 signs headers GCS's S3-compatible
  # API rejects as SignatureDoesNotMatch). Auth via GOOGLE_CREDENTIALS pointed at the
  # tofu-state-gcs-service-account BWS secret's JSON key - never committed to this repo.
  backend "gcs" {
    bucket = "amerenda-dean-tofu-state"
    prefix = "k3s/app-of-apps"
  }
}

# kubectl_manifest (not hashicorp/kubernetes's kubernetes_manifest): ApplicationSet's generator
# templates use Go-template `{{...}}` syntax that trips kubernetes_manifest's strict OpenAPI
# schema validation at plan time. kubectl_manifest applies via server-side apply as a YAML blob,
# no schema round-trip needed.
provider "kubectl" {
  config_path      = var.kubeconfig_path
  load_config_file = true
}

variable "kubeconfig_path" {
  description = "Path to the gmktec kubeconfig (points at the VIP, 10.100.20.161)"
  type        = string
  default     = "~/.kube/gmktec.yaml"
}
