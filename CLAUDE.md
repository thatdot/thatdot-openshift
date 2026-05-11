# Claude Code context — thatdot-openshift

## What this is

Discovery + first implementation pass to deploy Quine Enterprise into Red Hat OpenShift, on a local OpenShift Local (formerly CRC) cluster. Tracking ticket: **[QU-2539](https://thatdot.atlassian.net/browse/QU-2539)**.

The canonical document is **[`IMPLEMENTATION_PLAN.md`](./IMPLEMENTATION_PLAN.md)** — read it first. It has prerequisites, a 6-step walking-skeleton plan with verification per step, and a TL;DR checklist at the bottom that tracks progress.

## Critical rules

- **This repo is public on GitHub.** Never commit license keys, admin passwords, customer details, internal cluster URLs, or TLS private material. Secrets flow in via env vars at deploy time → `oc create secret`. Manifests reference secrets by name only.
- **OpenShift-native lane is the deliberate choice.** When recommending tooling or patterns, default to OpenShift-native equivalents (Operators from OperatorHub, Routes, `service-ca`, OpenShift GitOps) rather than upstream patterns from `enterprise-oauth-reference`.
- **Manifest-driven, not UI-driven.** All cluster state — operator Subscriptions, Namespaces, ArgoCD Applications, RoleBindings, everything — is expressed as YAML in this repo and applied via `oc apply` (for `bootstrap/` items) or GitOps sync (for `manifests/`). The OperatorHub web console is a *discovery* tool only; never install something through clicks without committing the resulting manifest. This is what makes the eventual production deployment reproducible from a clone.
- **Semantic naming, not step-numbered.** Files and directories are named by what they *are*, not by which step introduced them. `application-quine-enterprise.yaml`, `manifests/quine-enterprise/`, `manifests/cassandra/`, etc. Step numbers live in branch names (`step-2-basic-qe`) and the `IMPLEMENTATION_PLAN.md`, never in repo paths. (Step 1 used `step-1` paths; that was a v1 mistake corrected during step 2.)
- **Walking-skeleton order matters.** Don't skip ahead from step N to step N+2. Each step's verification is the gate for the next.
- **Cross-service ordering uses sync-waves *and* `initContainer` probes — complementary layers, both required when there's a dependency.** Sync-waves (annotations on Application CRs and on resources within an Application) order what ArgoCD *applies* — Subscription before its CR-using Applications, platform wrapper before product wrapper, etc. They do *not* gate runtime readiness: ArgoCD reports "Healthy" before services are necessarily serving, and waves don't re-fire on later pod restarts. So every long-running workload that depends on another service MUST also ship an `initContainer` that probes the dep at runtime and exits 0 only once it's reachable. Canonical examples:
  - **TCP probe** for "is the dep listening?" — `manifests/quine-enterprise/patches/wait-for-cassandra.yaml` uses bash `</dev/tcp/HOST/PORT` against `quine-dc1-service:9042`. Good for services where listening means ready (Cassandra accepts CQL connections only when fully bootstrapped).
  - **Application-layer probe** for "is the dep AND its config ready?" — `manifests/quine-enterprise/patches/wait-for-keycloak.yaml` (step 6) curls `/realms/quine-enterprise/.well-known/openid-configuration`. The discovery endpoint only returns 200 when both Keycloak is up AND the realm exists, so one probe covers both the service and the data dependency. Prefer application-layer probes when the readiness signal needs to include "the operator finished its reconcile job," not just "the pod is listening."
  - **Both patterns are resilient to *subsequent* dep outages** — every pod restart re-probes, so QE waiting for Keycloak after a Keycloak pod bounce just works.

## Architectural decisions (locked in)

| Decision | Choice | Rationale |
|---|---|---|
| Local cluster | OpenShift Local (CRC) | Same OCP bits as a production OpenShift cluster |
| GitOps engine | OpenShift GitOps Operator | Red Hat–native; the standard OpenShift GitOps path |
| TLS source | OpenShift `service-ca` (in-cluster) + default Route edge cert | Zero-install; no PEM material in public repo |
| Cassandra auth | None (`AllowAllAuthenticator`) | Out of v1 scope; defer JWT auth |
| Out of v1 scope | Novelty, Kafka | Reduce surface area for discovery |

## Reference repositories

Two prior-art K8s deployments to consult — *do not* copy patterns blindly; favor OpenShift-native equivalents.

- **`../opstools/keycloak/`** — *preferred starting point.* Helm-based, simpler. QE + Novelty + Keycloak + Cassandra (PLAINTEXT). Closest match to v1 scope.
- **`../thatdot-auth-services/`** (= [github.com/thatdot/enterprise-oauth-reference](https://github.com/thatdot/enterprise-oauth-reference)) — richer reference. ArgoCD pure-local mode, full PKI, Cassandra JWT, Kafka OAUTHBEARER. Use when v1's needs grow.

## Common commands

```bash
# Cluster
crc start --pull-secret-file ~/Downloads/pull-secret.txt
crc stop
eval "$(crc oc-env)"
oc whoami
oc console        # opens OpenShift web console
crc console --credentials   # admin password

# Bootstrap (idempotent — re-run any time)
./scripts/bootstrap.sh

# Diagnostics
oc get pods -A | grep -E "thatdot-openshift|gitops|operators"
oc describe pod -n thatdot-openshift <pod> | grep -E "scc|runAsUser|Status"
oc logs -n thatdot-openshift -l app=<label>
oc get application -n openshift-gitops
oc get csv -n openshift-operators

# Secrets (out-of-band)
oc create secret generic qe-license --from-literal=license-key="$QE_LICENSE_KEY"
```

## File layout

```
IMPLEMENTATION_PLAN.md       # canonical plan + checklist (start here)
README.md                    # external-facing entry point
CLAUDE.md                    # this file
.gitignore                   # secret-shaped patterns blocked
.pre-commit-config.yaml      # gitleaks hook

bootstrap/                   # Applied directly with `oc apply` (NOT GitOps-synced).
                             # Means: "applied imperatively because GitOps can't (yet) manage it."
                             # Four files only:
  gitops-operator-subscription.yaml   # OpenShift GitOps Operator install (chicken-and-egg: ArgoCD can't manage its own install)
  argocd-customizations.yaml          # ArgoCD CR patch: --enable-helm + CassandraDatacenter Lua health check
  namespace-thatdot-openshift.yaml    # Shared workload namespace + managed-by label.
                                      # Preconditional — operator-provisioned RoleBinding must exist
                                      # before ArgoCD syncs into the namespace; secrets need it too.
  root-application.yaml               # Single seed; ArgoCD takes over from here.

manifests/                   # GitOps-synced. The 3-level app-of-apps tree:
                             #   root --> platform (wave 0) --> cass-operator + cassandra leaf
                             #        \-> product  (wave 1) --> quine-enterprise leaf
  root/                      # What root-application.yaml syncs.
    kustomization.yaml       #   resources: [application-platform.yaml, application-product.yaml]
    application-platform.yaml   # sync-wave "0"; itself an app-of-apps over manifests/platform/
    application-product.yaml    # sync-wave "1"; itself an app-of-apps over manifests/product/

  platform/                  # ArgoCD Apps for platform/infra workloads.
                             # Only Application CRs live here — operator subs live INSIDE each leaf.
                             # See "single-Application boundary" pattern note below.
    kustomization.yaml
    application-cassandra.yaml        # ArgoCD App for the Cassandra stack    (sync-wave "1")
    application-keycloak.yaml         # ArgoCD App for the Keycloak stack     (sync-wave "1")

  product/                   # ArgoCD Apps for differentiating workloads.
                             # Future home of Novelty, etc.
    kustomization.yaml
    application-quine-enterprise.yaml

  # Single-Application boundary pattern (adopted step 5; applies to every platform-layer leaf):
  # operators + workload CRs together in one leaf, ordered by sync-wave annotations.
  # `oc delete application <name>` recreates the whole stack cold. Same rule for both leaves.

  cassandra/                 # LEAF: synced by manifests/platform/application-cassandra.yaml.
    kustomization.yaml
    cass-operator-subscription.yaml   # Subscription, sync-wave "0"
    serviceaccount.yaml               # anyuid RoleBinding, sync-wave "0" (see step 3 SCC gotcha)
    cassandradatacenter.yaml          # CassandraDatacenter CR, sync-wave "1"

  keycloak/                  # LEAF: synced by manifests/platform/application-keycloak.yaml.
                             # KeycloakRealmImport is fire-once — `oc delete application keycloak`
                             # is the natural workflow for realm-config iteration.
    kustomization.yaml
    rhbk-operator-subscription.yaml   # Subscription, sync-wave "0"
    postgres.yaml                     # Bare Postgres: PVC + Deployment + Service, sync-wave "1"
                                      # (CNPG was the original plan; pivoted because "cloud-native-postgresql"
                                      # in OperatorHub is EDB's paid product — see step 5 gotchas.)
    keycloak.yaml                     # RHBK Keycloak CR, sync-wave "2"
    route.yaml                        # edge-terminated Route, sync-wave "2"
    keycloak-realm-import.yaml        # KeycloakRealmImport CR, sync-wave "3" (fire-once)

  quine-enterprise/          # LEAF: synced by manifests/product/application-quine-enterprise.yaml.
    kustomization.yaml       #   helmCharts: QE 0.5.3, resources: route.yaml, patches: wait-for-cassandra
    values.yaml
    route.yaml
    patches/
      wait-for-cassandra.yaml   # initContainer: blocks until Cassandra accepts CQL — the canonical
                                # cross-service runtime dependency pattern (see Critical Rules)

scripts/                     # Helper scripts (idempotent)
  bootstrap.sh               # Install GitOps Operator + patch ArgoCD + namespace + secrets + seed root
  trust-crc-ca.sh            # Trust CRC ingress CA in macOS keychain (Chrome/Safari)
  create-license-secret.sh   # $QE_LICENSE_KEY → qe-license Secret
  create-thatdot-registry-pull-secret.sh   # $THATDOT_REGISTRY_* → thatdot-registry-creds Secret
  create-keycloak-postgres-secret.sh       # random password → keycloak-postgres-app Secret
                                           # (idempotent — preserves existing password on re-run)
```

## Useful gotchas (from `enterprise-oauth-reference`)

- QE resource limits: `2Gi` request, `4Gi` limit, `-Xmx2g`. Without these, JVM uses 25% of node RAM and OOM-kills.
- Cassandra heap: cap to `512m` — CRC has limited memory.
- `--force-config` flag on QE so it uses YAML persistor config rather than the recipe's default ephemeral RocksDB.
- QE OIDC library (`oidc4s`) requires `https://` for the issuer URL — non-negotiable. `service-ca` handles this for in-cluster TLS.
- OpenShift `restricted-v2` SCC assigns a *random* UID. Helm charts pinning `runAsUser` will be rejected. Strip the field; let SCC pick. *(QE 0.5.3 chart's default `securityContext: {}` is empty — no override needed.)*
- **Every namespace ArgoCD syncs into needs the `argocd.argoproj.io/managed-by: openshift-gitops` label.** OpenShift GitOps's default ArgoCD is namespace-scoped by design; the operator watches for this label and provisions the RoleBinding. Without it, sync fails with "forbidden" on every resource. Same idiom on CRC and on a production OpenShift cluster.
- **Kustomize + helmCharts requires `--enable-helm` on the ArgoCD instance.** Set via `oc patch argocd openshift-gitops -n openshift-gitops --type merge -p '{"spec":{"kustomizeBuildOptions":"--enable-helm"}}'` in `bootstrap.sh`. Without it, `kustomization.yaml`'s `helmCharts:` blocks render as empty and you get a confusingly silent failure.
- **Moving image tags require `imagePullPolicy: Always`.** Tags like `:main` get repointed by the registry; `IfNotPresent` would serve the kubelet's stale cache forever. Pinned semver tags (`:0.5.3`) can stay `IfNotPresent`.
- **The QE 0.5.3 chart supports `imagePullSecrets` natively** (in `values.yaml`). No Kustomize patch needed; just set the field in our values file.
- Cassandra datacenter name is taken from the CR's `metadata.name` — keep Helm values' `cassandra.localDatacenter` aligned.
- **`KeycloakRealmImport` is fire-once.** Operator marks the CR `status.Done: True` after the import Job succeeds; subsequent edits to the `realm:` block are ignored. To re-import: `oc delete keycloakrealmimport quine-enterprise -n thatdot-openshift` (drift triggers ArgoCD to recreate it) — or, for a full stack reset, `oc delete application keycloak -n openshift-gitops`. This is why `manifests/keycloak/` uses the single-Application-boundary layout.
- **Operator-CRD chicken-and-egg in single-Application leaves.** When an Application contains both a Subscription (wave 0) and a CR whose CRD that Subscription installs (wave 1+), ArgoCD's pre-flight dry-run fails on the CR ("no matches for kind …") *before* wave 0 even gets a chance to install the operator — fails the whole sync after 5 retries. **Fix:** annotate the CRD-dependent resource with `argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true`. Sync-waves still order the apply correctly; this just disables the pre-flight validation that aborts the whole sync prematurely. Applied to: `CassandraDatacenter`, `Keycloak`, `KeycloakRealmImport`.
- **OperatorHub catalog gotcha: "cloud-native-postgresql" is EDB's commercial product.** The `cloud-native-postgresql` package in `certified-operators` is EDB Postgres for Kubernetes, NOT upstream CloudNativePG. Pulls from `docker.enterprisedb.com` and requires a paid subscription. Step 5 originally planned to use it; pivoted to bare Postgres Deployment (see `manifests/keycloak/postgres.yaml`) when this surfaced. If you need an operator-managed Postgres on OpenShift, the free alternative is `crunchy-postgres-operator` — different CR schema, mandatory pgBackRest config. Always verify with `oc describe packagemanifest <pkg> -n openshift-marketplace` and check the actual image registry before committing a Subscription.
- **Red Hat container images with a pinned `USER` directive need `fsGroup` to write to PVCs.** Images like `registry.redhat.io/rhel9/postgresql-16` declare `USER 26` (postgres). With OpenShift's `restricted-v2` SCC, UID 26 is outside the namespace's allowed range, so admission falls back to `anyuid` (which the `default` SA has from cass-operator's RoleBinding). The container runs as UID 26, but a freshly-bound PVC is owned `root:root` mode 755 — UID 26 can't write. Symptom: `mkdir: cannot create directory '/var/lib/pgsql/data/userdata': Permission denied`. **Fix:** set `securityContext.fsGroup: <image's GID>` on the pod; Kubernetes chowns the PVC mount to that group on attach. Pin `runAsUser`/`runAsGroup` explicitly too — makes SCC selection deterministic rather than relying on implicit fall-through. See `manifests/keycloak/postgres.yaml`.
- **RHBK ships an older `apiVersion` than upstream Keycloak Operator.** Upstream Keycloak 26 uses `k8s.keycloak.org/v2beta1`; Red Hat Build of Keycloak 26.4 still serves only `k8s.keycloak.org/v2alpha1`. The kinds and field names are identical between versions, just the `apiVersion` differs. Symptom if you copy from upstream docs: `no matches for kind "Keycloak" in version "k8s.keycloak.org/v2beta1"` at apply time, even though the CRD exists. **Always verify with** `oc get crd keycloaks.k8s.keycloak.org -o jsonpath='{.spec.versions[*].name}{"\n"}'` before writing manifests against an operator you haven't used before.
- **ArgoCD operations can deadlock when sync-waves wait on never-Healthy resources.** With sync-waves + automated sync, ArgoCD applies wave N and waits for all wave-N resources to be Healthy before applying wave N+1. If a wave-N resource enters CrashLoopBackOff, the operation hangs in `operationState.phase: Running` forever — and ArgoCD won't pick up new manifest edits because the current operation is still "in progress." Symptom: `oc get application <name> -o jsonpath='{.status.sync.revision}'` shows the latest Git commit, but the resource on cluster still has the old spec. **Fix:** terminate the stuck operation with `oc patch application <name> -n openshift-gitops --type=merge -p '{"operation":null}'`, then ArgoCD's automated sync picks up the new manifests on its next cycle (force with `argocd.argoproj.io/refresh=hard` annotation if impatient).

## When you finish a piece of work

- Update `IMPLEMENTATION_PLAN.md`: cross off the relevant TL;DR checklist item; if you diverged from the plan, edit the affected step rather than letting the plan drift.
- Add the corresponding section to `README.md` so the README is a real walk-through, not a stub.
- Verify nothing secret-shaped is staged before committing (`git diff --cached`).
