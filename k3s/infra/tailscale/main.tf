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

# Blocked on real BWS UUIDs from Alex - an OAuth client has to be created via the Tailscale admin
# console (not something Tofu/Ansible can do), then its client ID/secret stored in BWS. Applying
# oauth-externalsecret.yaml now (with its placeholder UUIDs) would create an ExternalSecret that
# can never sync. Uncomment once real UUIDs are in.
# resource "kubectl_manifest" "oauth" {
#   depends_on = [kubectl_manifest.application]
#   yaml_body  = file("${path.module}/oauth-externalsecret.yaml")
# }

# resource "kubectl_manifest" "connector" {
#   depends_on = [kubectl_manifest.application]
#   yaml_body  = file("${path.module}/connector.yaml")
# }
