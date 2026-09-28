# Tailscale: hand-rolled Deployment mirroring k3s-dean-gitops's infra/tailscale/ (see
# tailscale.yaml for why - not the K8s Operator, no OAuth client credentials provisioned).
#
# tailscale.yaml has 6 --- separated documents (Namespace/ServiceAccount/ClusterRole/
# ClusterRoleBinding/Deployment/PDB) - kubectl_manifest only supports one resource per yaml_body,
# so this uses the provider's own documented multi-document pattern (kubectl_path_documents +
# for_each) instead of hand-splitting into 6 files.
data "kubectl_path_documents" "tailscale" {
  pattern = "${path.module}/tailscale.yaml"
  # tailscale.yaml's embedded shell script uses ${POD_NAME} (a real shell variable) - this data
  # source treats file content as a Tofu template by default and misreads that as an attempted
  # Tofu interpolation. No actual Tofu variables need injecting here, so just disable it.
  disable_template = true
}

resource "kubectl_manifest" "tailscale" {
  for_each  = data.kubectl_path_documents.tailscale.manifests
  yaml_body = each.value
}

resource "kubectl_manifest" "tailscale_auth_key" {
  depends_on = [kubectl_manifest.tailscale]
  yaml_body  = file("${path.module}/tailscale-externalsecret.yaml")
}
