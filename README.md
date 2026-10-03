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
- `k3s/infra/{prod,dev}/` - shared applications required for the environment, not the cluster itself
  (Tailscale, monitoring, build/CI runners, DDNS, llmkube). Not started.
- `k3s/apps/{prod,dev}/` - Alex's own applications (Wikimedia, Ecdysis, Praetor, etc.). Per the reconciliation
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

## Bitwarden Secrets Manager provider auth

Modules that use the `bitwarden-secrets` provider (e.g. `modules/app-postgres`) read their auth from
the environment, never from this repo:

- `BW_ACCESS_TOKEN` - a machine-account token. Read-only is enough for `plan`; `apply`/`destroy` that
  create or delete secrets need the write-capable token.
- `BW_ORGANIZATION_ID` - `a9b83b36-d37e-4532-88a4-b36f00df7f3d` (an identifier, not a secret).

## Provider choice for raw manifests: `alekc/kubectl`, not `hashicorp/kubernetes`

`kubernetes_manifest` (the official `hashicorp/kubernetes` provider's generic-CRD resource) fetches
and validates against the target CRD's OpenAPI schema at plan time. ArgoCD's `ApplicationSet`
generator templates use Go-template `{{...}}` syntax inside fields schema validation doesn't
expect, which trips that check. `kubectl_manifest` (`alekc/kubectl`) applies via server-side apply
as a YAML blob instead, with no schema round-trip - simpler and more robust for this specific case.

## Sequencing within `k3s/app-of-apps/`: eager creation, accept transient crash-loops

Several resources have a real dependency on an earlier one existing (ESO's `ClusterSecretStore`
needs `bitwarden-sdk-server`'s TLS cert; `external-dns-do` needs the `do-dns-api-key` Secret; a
couple of small manifests need a CRD from an earlier chart to be registered). Two approaches were
tried and rejected before landing on the current one:

- **`argocd.argoproj.io/sync-wave` annotations do not order separate `ApplicationSet`-generated
  Applications relative to each other** - confirmed against ArgoCD's own docs/community: sync-waves
  only order resources *within* one Application's own sync. `ApplicationSet` is a generator, not an
  Application, so there's nothing for a wave to attach to across generated Applications.
- **`null_resource` + `local-exec` wait gates were built, then removed entirely** (Alex: no
  local-exec, under any circumstances - it's an imperative shell escape hatch inside otherwise-
  declarative IaC, and it introduced a real bug live: `KUBECONFIG="~/.kube/foo.yaml"` doesn't
  tilde-expand inside double quotes in bash).
- **Individual `kubectl_manifest` Application resources with the provider's native `wait_for`**
  (poll a live status condition, no shell) were designed and validated but never committed -
  rejected in favor of the simpler option below once it became clear the CA-bundle problem (the
  one piece that genuinely couldn't just "settle") had a real fix.

**What's actually used:** every resource in this tier is created eagerly, in one `tofu apply`, no
waiting. A resource with an unmet dependency just sits not-Ready/Degraded/CrashLoopBackOff until
that dependency appears, then self-heals on its own (`syncPolicy.automated.selfHeal: true` for
ArgoCD-managed Applications; ESO/cert-manager's own controllers reconcile their CRs on a timer
regardless). This works because the CRs are cheap to leave failing and every dependency here does
eventually resolve within the same apply's lifetime - `external-dns-do` has run this way
successfully since day one. Where a value would otherwise need to be read at apply time before it
exists (e.g. a CA certificate cert-manager hasn't issued yet), look for a live-reference field
first (`caProvider` instead of baking `caBundle` into the `ClusterSecretStore`, in ESO's case) -
check the actual live CRD schema (`kubectl get crd <name> -o json`) rather than assuming an older
chart version's values shape still applies.

**One accepted edge case, not engineered around:** on a genuinely from-scratch cluster, a resource
that needs another chart's CRD to exist (`selfsigned-issuer` needs cert-manager's `ClusterIssuer`
CRD; `cluster_secret_store` needs ESO's `ClusterSecretStore` CRD) could theoretically lose the race
if Tofu applies it before ArgoCD has synced the owning chart - this fails as a hard apply-time
error (not a crash-loop), and the fix is just running `tofu apply` a second time. In practice
CRDs land within seconds of a Helm release syncing, so this is a low-probability one-time hiccup,
not a repeat of the incremental debugging this design replaced.

## prod / dev layout

`k3s/infra/` and `k3s/apps/` each split into `prod/` and `dev/`. Everything live is under `prod/`
(`k3s/apps/prod/unifi/`, `k3s/infra/prod/tailscale/`, ...); `dev/` is empty. Each root's GCS state
prefix mirrors its path (`k3s/apps/prod/unifi`). `k3s/app-of-apps/` is cluster-level and stays
unsplit. Resources are scoped to the app they serve, not the operator they depend on (the UniFi
MongoDB replica set lives in `k3s/apps/prod/unifi/`, not `infra/prod/mongodb/`).
