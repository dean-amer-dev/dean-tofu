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
  # The Deployment among these 6 documents references tailscale-auth-key, which the
  # ExternalSecret below creates - but that's necessarily sequenced *after* this resource
  # (it needs the ServiceAccount/RBAC docs in the same for_each to exist first). Left at the
  # default (true), kubectl_manifest blocks up to 10 minutes waiting for the Deployment to roll
  # out, which can never happen until the secret exists - a self-inflicted deadlock. Same
  # eager-create-and-self-heal pattern as everywhere else instead: don't wait, let it sit
  # CreateContainerConfigError until the secret lands moments later.
  wait_for_rollout = false
}

resource "kubectl_manifest" "tailscale_auth_key" {
  depends_on = [kubectl_manifest.tailscale]
  yaml_body  = file("${path.module}/tailscale-externalsecret.yaml")
}
