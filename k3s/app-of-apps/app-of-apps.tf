# One ApplicationSet for the whole app-of-apps tier (List generator, elements inline - no
# git-manifests-repo). ArgoCD's own ApplicationSet controller fans this out into one real
# Application per element - cert-manager, ESO, reloader, external-dns-do, OpenEBS. Technitium and
# external-dns-technitium are deliberately not here yet (no chart, needs its own StatefulSet
# design + a decision on where hand-written manifests live - see infra2-app-of-apps-background-draft.md).
#
# Note on sync-wave annotations: they order resources *within* one Application's own sync, not
# between separate ApplicationSet-generated Applications - so they don't make ArgoCD wait for
# cert-manager to finish before starting ESO's sync. ESO's chart will attempt to sync at the same
# time as cert-manager; its sidecar TLS Certificate (referencing selfsigned-issuer, created below
# once cert-manager's CRDs exist) will be degraded/erroring for a short window until selfsigned-
# issuer exists, then self-heal automatically (syncPolicy.automated.selfHeal: true) - same pattern
# already used for ArgoCD's own Ingress in Phase 0.
resource "kubectl_manifest" "app_of_apps" {
  yaml_body = file("${path.module}/applicationset.yaml")
}

# selfsigned-issuer needs cert-manager's CRDs to exist first - they're installed by the Helm chart
# above, asynchronously, after this resource returns. Block here until they're actually Established
# rather than racing ahead (kubectl_manifest itself has no "retry until CRD exists" behavior).
resource "null_resource" "wait_cert_manager_crds" {
  depends_on = [kubectl_manifest.app_of_apps]

  provisioner "local-exec" {
    # kubectl wait errors immediately ("no matching resources") if the resource doesn't exist yet
    # rather than waiting for creation - so poll for existence first, then wait for the real
    # condition, instead of relying on `--for=create` (not in every kubectl version).
    command = <<-EOT
      set -e
      export KUBECONFIG="${var.kubeconfig_path}"
      for crd in clusterissuers.cert-manager.io certificates.cert-manager.io; do
        for i in $(seq 1 60); do kubectl get crd "$crd" >/dev/null 2>&1 && break; sleep 5; done
        kubectl wait --for=condition=Established --timeout=300s crd/"$crd"
      done
      for i in $(seq 1 60); do kubectl get deployment cert-manager -n app-of-apps >/dev/null 2>&1 && break; sleep 5; done
      kubectl wait --for=condition=Available --timeout=300s deployment/cert-manager -n app-of-apps
    EOT
  }
}

resource "kubectl_manifest" "selfsigned_issuer" {
  depends_on = [null_resource.wait_cert_manager_crds]
  yaml_body  = file("${path.module}/selfsigned-issuer.yaml")
}

# OpenEBS's CSI driver registers itself asynchronously too; wait before creating the StorageClass
# so it isn't left pointing at a provisioner that doesn't exist yet on first apply.
resource "null_resource" "wait_openebs_csi" {
  depends_on = [kubectl_manifest.app_of_apps]

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      export KUBECONFIG="${var.kubeconfig_path}"
      for i in $(seq 1 60); do kubectl get csidriver local.csi.openebs.io >/dev/null 2>&1 && break; sleep 5; done
      kubectl get csidriver local.csi.openebs.io
    EOT
  }
}

resource "kubectl_manifest" "openebs_storageclass" {
  depends_on = [null_resource.wait_openebs_csi]
  yaml_body  = file("${path.module}/storageclass.yaml")
}

# --- Not yet wired: ESO's ClusterSecretStore, the do-dns-api-key ExternalSecret, and the ACME
# ClusterIssuer. ClusterSecretStore needs the bitwarden-sdk-server's CA cert (issued by
# selfsigned-issuer, via ESO's own chart) fed into its caBundle field - that only exists once ESO's
# Certificate actually resolves, which itself only happens after selfsigned_issuer above is live.
# Chaining that in blind, in the same apply Alex has to run without a chance to check state in
# between, risks a broken ClusterSecretStore he then has to debug from a large diff. Next step
# once this apply is confirmed healthy: read the issued bitwarden-tls-certs secret's ca.crt via a
# kubernetes_secret data source and wire the remaining 3 resources in a follow-up apply. ---
