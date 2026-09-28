# One ApplicationSet for the app-of-apps tier (List generator, elements inline - no
# git-manifests-repo). ArgoCD's own ApplicationSet controller fans this out into one real
# Application per element: cert-manager, ESO, reloader, external-dns-do, OpenEBS. Technitium and
# external-dns-technitium are deliberately not here yet (no chart, needs its own StatefulSet
# design + a decision on where hand-written manifests live).
resource "kubectl_manifest" "app_of_apps" {
  # templatefile (not file): stamps a fresh argocd.argoproj.io/refresh annotation on every apply
  # (see applicationset.yaml.tftpl) so ArgoCD re-evaluates immediately instead of waiting out its
  # own retry backoff or reconcile-poll interval.
  yaml_body = templatefile("${path.module}/applicationset.yaml.tftpl", {
    refresh_token = timestamp()
  })
}

# selfsigned-issuer needs cert-manager's CRDs to exist. No wait mechanism here (no local-exec, per
# Alex - and no provider-native way to wait on a *different* resource's status than the one Tofu is
# managing, since this isn't a resource kubectl_manifest itself creates with a wait_for). Cert-
# manager's CRDs land within seconds of its Helm release syncing (CRDs are near the first objects
# any Helm install applies) - if this ever does lose the race on a from-scratch apply, `tofu apply`
# is idempotent and safe to just re-run once the CRDs exist, same as any other eventually-consistent
# apply against an async controller.
resource "kubectl_manifest" "selfsigned_issuer" {
  depends_on = [kubectl_manifest.app_of_apps]
  yaml_body  = file("${path.module}/selfsigned-issuer.yaml")
}

# StorageClass is a core API type (storage.k8s.io/v1) - always creatable regardless of whether
# OpenEBS's CSI driver has registered yet. It simply provisions nothing until the driver exists, so
# there's no real ordering dependency to wait on here at all.
resource "kubectl_manifest" "openebs_storageclass" {
  depends_on = [kubectl_manifest.app_of_apps]
  yaml_body  = file("${path.module}/storageclass.yaml")
}

# --- Not yet wired: ESO's ClusterSecretStore, the do-dns-api-key ExternalSecret, and the ACME
# ClusterIssuer. ClusterSecretStore needs the bitwarden-sdk-server's CA cert (issued by
# selfsigned-issuer, via ESO's own chart) - read live via a kubectl_manifest data source once that
# cert actually exists, in a follow-up apply, rather than assuming its value now. ---
