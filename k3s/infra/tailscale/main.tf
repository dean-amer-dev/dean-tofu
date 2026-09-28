terraform {
  required_providers {
    kubectl = {
      source = "alekc/kubectl"
    }
  }
}

# Tofu only bootstraps the ArgoCD Application. Everything else for Tailscale (the operator-oauth
# ExternalSecret, the Connector) lives in ./manifests and is deployed by ArgoCD as the
# Application's second source, from main.
resource "kubectl_manifest" "application" {
  yaml_body = file("${path.module}/application.yaml")
}

# These two used to be Tofu-managed; ArgoCD owns them now. destroy = false drops them from state
# without deleting the live objects, so ArgoCD adopts them in place.
removed {
  from = kubectl_manifest.oauth
  lifecycle {
    destroy = false
  }
}

removed {
  from = kubectl_manifest.connector
  lifecycle {
    destroy = false
  }
}
