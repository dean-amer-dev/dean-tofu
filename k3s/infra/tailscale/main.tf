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

resource "kubectl_manifest" "oauth" {
  depends_on = [kubectl_manifest.application]
  yaml_body  = file("${path.module}/oauth-externalsecret.yaml")
}

resource "kubectl_manifest" "connector" {
  depends_on = [kubectl_manifest.application]
  yaml_body  = file("${path.module}/connector.yaml")
}
