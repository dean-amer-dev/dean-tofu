terraform {
  required_providers {
    kubectl = {
      source = "alekc/kubectl"
    }
  }
}

resource "kubectl_manifest" "application" {
  yaml_body = file("${path.module}/application.yaml")
}

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
