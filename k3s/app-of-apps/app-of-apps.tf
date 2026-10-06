# One ApplicationSet for the app-of-apps tier (List generator, elements inline - no
# git-manifests-repo). ArgoCD's own ApplicationSet controller fans this out into one real
# Application per element: cert-manager, ESO, reloader, external-dns-do, OpenEBS. Technitium and
# external-dns-technitium are deliberately not here yet (no chart, needs its own StatefulSet
# design + a decision on where hand-written manifests live).
resource "kubectl_manifest" "app_of_apps" {
  # Plain file, not templatefile(): a prior version of this stamped a fresh
  # argocd.argoproj.io/refresh annotation on every apply via timestamp(), to force ArgoCD to
  # re-evaluate immediately instead of waiting out its retry backoff. Removed - it caused a live
  # reconcile storm: the ApplicationSet controller continuously re-asserts its template against
  # the generated Application, and the app-controller clears the refresh annotation the instant it
  # processes it, so the two fought in a tight loop (Alex saw the ArgoCD UI refreshing ~5x/second
  # on every app in the tier). A slower sync after a genuinely-failing apply, occasionally needing
  # a manual `argocd app sync`, is a much smaller cost than a permanent reconcile storm.
  yaml_body = file("${path.module}/applicationset.yaml")
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

# The bitwarden-sdk-server subchart does NOT create this itself (verified via `helm show values`
# against the real chart in use - no tls.certManager field exists there, only image.tls.enabled
# expecting a pre-existing Secret). See bitwarden-sdk-server-tls.yaml for the full reasoning.
resource "kubectl_manifest" "bitwarden_sdk_server_tls" {
  depends_on = [kubectl_manifest.selfsigned_issuer]
  yaml_body  = file("${path.module}/bitwarden-sdk-server-tls.yaml")
}

# Created eagerly (needs ESO's ClusterSecretStore CRD, from the app_of_apps ApplicationSet).
# Uses caProvider (reads the CA from bitwarden-tls-certs at runtime), not a Tofu-side read of a
# value that might not exist yet - so this never has to wait for bitwarden_sdk_server_tls to
# actually finish issuing. Sits not-Ready until that Secret exists, then self-heals - accepted
# per Alex, simpler than chaining a wait for it.
resource "kubectl_manifest" "cluster_secret_store" {
  depends_on = [kubectl_manifest.app_of_apps]
  yaml_body  = file("${path.module}/clustersecretstore.yaml")
}

# Sits Pending until cluster_secret_store is actually Ready, then self-heals - same pattern.
resource "kubectl_manifest" "do_dns_external_secret" {
  depends_on = [kubectl_manifest.cluster_secret_store]
  yaml_body  = file("${path.module}/do-dns-externalsecret.yaml")
}

# Doesn't need do_dns_external_secret's Secret to exist at create time (only when cert-manager
# actually tries to issue a cert against it) - just needs cert-manager's CRD, guaranteed by
# selfsigned_issuer's successful creation.
resource "kubectl_manifest" "acme_staging_issuer" {
  depends_on = [kubectl_manifest.selfsigned_issuer]
  yaml_body  = file("${path.module}/acme-clusterissuer.yaml")
}

# Cut over 2026-09-28 - see acme-clusterissuer-prod.yaml's header comment.
resource "kubectl_manifest" "acme_prod_issuer" {
  depends_on = [kubectl_manifest.selfsigned_issuer]
  yaml_body  = file("${path.module}/acme-clusterissuer-prod.yaml")
}

# Longhorn backups to GCS: credentials ExternalSecret, the daily backup RecurringJob (retain 14 =
# 14 days) and two StorageClasses. "longhorn-backup" carries the backup-daily selector,
# "longhorn-no-backup" has none (opt-out). The chart's own "longhorn" class is disabled
# (createStorageClass: false). Sits Pending until the longhorn Application has installed its CRDs.
data "kubectl_file_documents" "longhorn_backup" {
  content = file("${path.module}/longhorn-backup.yaml")
}

resource "kubectl_manifest" "longhorn_backup" {
  for_each   = data.kubectl_file_documents.longhorn_backup.manifests
  depends_on = [kubectl_manifest.app_of_apps, kubectl_manifest.cluster_secret_store]
  yaml_body  = each.value
}
