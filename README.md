# dean-tofu

OpenTofu configs for the gmktec k3s cluster (Infrastructure 2.0). See
`infra2-app-of-apps-plan-draft.md` / `infra2-app-of-apps-background-draft.md` in `~/claude/instructions/`
for the full design history (copied into the `Dean` Obsidian vault once `obsidian-mcp` is reachable
again).

## Model

Ansible bootstraps only Cilium, CoreDNS, kube-vip and ArgoCD (plus one bootstrap credential) on the
gmktec cluster - nothing else. Everything past that is created directly by Tofu, which ArgoCD then
syncs:

- **Tofu creates ArgoCD `Application`/`ApplicationSet` objects** (chart + version + values) - it
  never emits raw workload manifests itself, except for a handful of small supporting resources
  (ClusterIssuers, StorageClasses, ClusterSecretStores) that don't come from any Helm chart.
- **No git-manifests-repo.** Unlike the legacy cluster's `dean-helm-app` app-of-apps pattern, chart
  versions and values are pinned directly in this repo's `.tf`/`.yaml` files, not committed
  manifests ArgoCD pulls from git.
- **No Tofu runner.** Alex runs `tofu apply` himself - this is not automated or scheduled.

## Three-tier taxonomy

- `k3s/app-of-apps/` - things required for the cluster to function at all (cert-manager, ESO,
  reloader, external-dns, OpenEBS, Technitium). One `ApplicationSet` per tier (`List` generator,
  elements inline), not one `Application` per component - see the background note's
  "ApplicationSet over flat Tofu-created Applications" section for why.
- `k3s/infra/` - shared applications required for the environment, not the cluster itself
  (Tailscale, monitoring, build/CI runners, DDNS, llmkube). Not started.
- `k3s/apps/` - Alex's own applications (Wikimedia, Ecdysis, Praetor, etc.). Per the reconciliation
  with the vault's canonical `cluster-build-and-migration.md`, this tier does **not** get its own
  `ApplicationSet` - it follows the vault's model instead (tofu/`app-factory` creates one ArgoCD
  `Application` per app, pointing at a kustomize overlay or Helm chart in git). Not started.

## State backend

GCS bucket `gs://amerenda-dean-tofu-state`, versioned - the vault's canonical plan's choice, not
the in-cluster Kubernetes Secret this design originally assumed (reconciled 2026-09-30). Auth via
`GOOGLE_CREDENTIALS` pointed at the `tofu-state-gcs-service-account` BWS secret's JSON key - never
committed to this repo. The native `gcs` backend is used, not the `s3` backend type against GCS's
S3-interop endpoint - `app-factory/tofu/main.tf` documents that HMAC keys fail there (AWS SDK Go v2
signs headers GCS's S3-compatible API rejects as `SignatureDoesNotMatch`).

## Provider choice for raw manifests: `alekc/kubectl`, not `hashicorp/kubernetes`

`kubernetes_manifest` (the official `hashicorp/kubernetes` provider's generic-CRD resource) fetches
and validates against the target CRD's OpenAPI schema at plan time. ArgoCD's `ApplicationSet`
generator templates use Go-template `{{...}}` syntax inside fields schema validation doesn't
expect, which trips that check. `kubectl_manifest` (`alekc/kubectl`) applies via server-side apply
as a YAML blob instead, with no schema round-trip - simpler and more robust for this specific case.

## Sequencing within `k3s/app-of-apps/`

Several components have a real dependency on an earlier one's CRDs or certificates existing (ESO's
sidecar TLS cert needs cert-manager's `selfsigned-issuer`, which needs cert-manager's CRDs
installed and synced first). `argocd.argoproj.io/sync-wave` annotations only order resources
*within* one Application's own sync - they do **not** make ArgoCD wait for one
ApplicationSet-generated Application to be Healthy before starting the next one's sync. Real
cross-component ordering inside one `tofu apply` is handled with `null_resource` +
`local-exec` wait gates (poll for the resource to exist, then wait for its real condition) chained
via `depends_on` - see `app-of-apps.tf`. Where a dependency crosses an `ApplicationSet`-generated
Application's *own* health (not just a raw manifest Tofu also owns directly), the design instead
leans on `syncPolicy.automated.selfHeal: true` to converge shortly after the dependency appears,
same pattern already used for ArgoCD's own Ingress in Phase 0 (created before cert-manager/external-dns
existed, picked up automatically once they did).
