# thatdot-openshift

Reference deployment of [Quine Enterprise](https://www.thatdot.com/quine-enterprise) onto Red Hat OpenShift, with Cassandra as its persistor and Keycloak for OIDC-based RBAC.

> **Status:** step 5 of 6 complete — Quine Enterprise + Cassandra + Keycloak (RHBK) deployed via the app-of-apps cascade. The `quine-enterprise` realm with 6 client roles, 6 interactive users, and 6 service-account CLI clients is pre-configured. RBAC is fully provisioned on the Keycloak side; wiring QE to consume it is step 6. See [`IMPLEMENTATION_PLAN.md`](./IMPLEMENTATION_PLAN.md) for progress.

## What's here

- **[`IMPLEMENTATION_PLAN.md`](./IMPLEMENTATION_PLAN.md)** — prerequisites, step-by-step deployment plan with verification at each step, and a TL;DR checklist at the bottom.
- **[`CLAUDE.md`](./CLAUDE.md)** — context for engineers (and Claude Code) picking up the work, including a "Useful gotchas" section that's grown a lot over the last few steps.
- `bootstrap/` — applied directly (`oc apply`); the only things GitOps can't manage itself. Four files: the GitOps Operator Subscription, the `argocd-customizations.yaml` patch (Kustomize+Helm + health checks for `CassandraDatacenter` / `Keycloak` / `KeycloakRealmImport`), the shared `thatdot-openshift` namespace, and `root-application.yaml` (the single seed for everything else).
- `manifests/root/` — synced by `root-application`. Contains `application-platform.yaml` (sync-wave 0) and `application-product.yaml` (sync-wave 1) — the two children of the root.
- `manifests/platform/` — synced by `application-platform`. Holds **only** ArgoCD Application CRs now (no operator subscriptions at the wrapper layer). Two children: `application-cassandra` and `application-keycloak`, both sync-wave 1.
- `manifests/product/` — synced by `application-product`. ArgoCD Applications for differentiating workloads (today: QE; future: Novelty).
- `manifests/cassandra/` — leaf synced by `application-cassandra`. **Whole Cassandra stack** in one Application boundary: the cass-operator Subscription (wave 0), the `anyuid` RoleBinding for the namespace's `default` SA (wave 0), and the `CassandraDatacenter` CR (wave 1).
- `manifests/keycloak/` — leaf synced by `application-keycloak`. **Whole Keycloak stack** in one Application boundary: the RHBK operator Subscription (wave 0), a bare Postgres Deployment+PVC+Service (wave 1), the `Keycloak` CR + edge-terminated Route (wave 2), and the `KeycloakRealmImport` CR that loads the `quine-enterprise` realm (wave 3).
- `manifests/quine-enterprise/` — leaf synced by `application-quine-enterprise`. Kustomize root that pulls the QE Helm chart from `helm.thatdot.com`, renders with `values.yaml`, adds an OpenShift Route + a `wait-for-cassandra` init container patch. (Step 6 will add OIDC config + a `wait-for-keycloak` init container.)
- `scripts/` — `bootstrap.sh` (idempotent cluster bootstrap, fail-fast on missing env vars; ends by seeding the root Application), `trust-crc-ca.sh` (browser trust), `create-license-secret.sh`, `create-thatdot-registry-pull-secret.sh`, `create-keycloak-postgres-secret.sh` (random password for Keycloak's Postgres backing store; idempotent — preserves existing password on re-run).

## Target environment

Single-node [OpenShift Local](https://developers.redhat.com/products/openshift-local) (formerly CRC) for dev iteration. Same OpenShift Container Platform bits as a production cluster.

## Architectural decisions

| | Choice |
|---|---|
| GitOps engine | OpenShift GitOps Operator (Red Hat–packaged ArgoCD) |
| Edge TLS | OpenShift router default wildcard cert (no cert-manager) |
| Cassandra auth | None (`AllowAllAuthenticator`) — out of scope for v1 |
| Identity | Red Hat Build of Keycloak (RHBK) Operator — `Keycloak` + `KeycloakRealmImport` on `k8s.keycloak.org/v2alpha1` |
| Keycloak DB | Bare Postgres Deployment (the OperatorHub `cloud-native-postgresql` package is EDB's paid product; upstream CNPG isn't shipped in the curated catalogs) |
| Platform-stack layout | Single-Application boundary per stack: each leaf in `manifests/platform/`'s children owns its own operator Subscription + workload CRs, wired up with intra-leaf sync-waves. `oc delete application <name>` recreates the whole stack cold — the natural debug primitive when an operator-driven Job (like `KeycloakRealmImport`) needs a fresh run. |

## Conventions

**Cross-service ordering uses ArgoCD sync-waves *and* `initContainer` probes — complementary layers, not alternatives.** Sync-waves order what ArgoCD *applies* (e.g., cass-operator Subscription before its CR-using Application; the platform wrapper before the product wrapper). InitContainers gate *runtime startup* on every pod start (e.g., `wait-for-cassandra` blocks QE until CQL is reachable). Either alone is insufficient: ArgoCD reports "Synced + Healthy" before services are fully serving and doesn't re-fire on later pod restarts; meanwhile a CR can't be applied before its CRD exists. Use both. Canonical init container: `manifests/quine-enterprise/patches/wait-for-cassandra.yaml` (TCP connect via bash `</dev/tcp/HOST/PORT`).

## Public-repo notice

This repository is public. **No license keys, admin passwords, internal cluster details, or TLS private material are committed here.** All secrets flow in at deploy time via environment variables and `oc create secret` commands, documented in `IMPLEMENTATION_PLAN.md`.

## Out of scope for v1

- Novelty
- Kafka

These may be added in a follow-up.

---

## Quick start — reproduce the current cluster state

The repo's bootstrap is idempotent: a single `./scripts/bootstrap.sh` applies everything that's been built so far.

```bash
# 1. Start your CRC cluster (see IMPLEMENTATION_PLAN.md → Prerequisites for first-time install)
crc start --pull-secret-file ~/Downloads/pull-secret.txt
eval "$(crc oc-env)"
oc login -u kubeadmin -p <pw> https://api.crc.testing:6443     # `crc console --credentials` for pw

# 2. (Optional) trust the CRC ingress CA so browsers don't warn on cluster Routes
./scripts/trust-crc-ca.sh

# 3. Source the required env vars (license + private-registry credentials)
#    Suggested home: ~/.zshrc.local — see IMPLEMENTATION_PLAN.md → Prerequisites
export QE_LICENSE_KEY="..."
export THATDOT_REGISTRY_USERNAME="..."
export THATDOT_REGISTRY_PASSWORD="..."

# 4. Bootstrap (preflight will fail clearly if any env var above is missing)
./scripts/bootstrap.sh
```

After ArgoCD reports `Synced + Healthy`:

```bash
oc get application -n openshift-gitops              # root + 4 children → Synced + Healthy
ROUTE=$(oc get route quine-enterprise -n thatdot-openshift -o jsonpath='{.spec.host}')
open "https://$ROUTE"                               # browser: QE landing page (no RBAC yet — that's step 6)
```

## Steps so far

### Step 1 — Hello, OpenShift *(retired)*

**What it proved:** the full GitOps loop end-to-end on a known-good workload (nginx) before any product complexity. GitHub → OpenShift GitOps Operator → ArgoCD → manifest sync → OpenShift Route → browser.

**Why retired:** nginx was a stand-in for the GitOps mechanics. Step 2 replaced it with the real workload (Quine Enterprise) in the same namespace. The Application + manifests for nginx were removed at the end of step 2.

**Gotchas surfaced (still apply to every subsequent step):**

1. **Non-root container image required.** OpenShift's `restricted-v2` SCC assigns a random UID and forbids binding ports below 1024. Standard `nginx:latest` runs as root and binds port 80, so it crashloops. Step 1 used `nginxinc/nginx-unprivileged:latest` (binds 8080 as non-root); step 2's QE chart already runs non-root by default.
2. **Target namespace must carry `argocd.argoproj.io/managed-by: openshift-gitops`.** OpenShift GitOps's default ArgoCD instance is namespace-scoped — it can only manage resources in `openshift-gitops` until granted permissions elsewhere. The label tells the operator to provision the RoleBinding automatically. Without it, sync fails "forbidden" on every namespaced resource.

### Step 2 — Quine Enterprise standalone

**What it proves:** QE runs under `restricted-v2` SCC; the private-registry pull-secret pattern works; Kustomize+Helm rendering works under OpenShift GitOps; Route + edge TLS work for an actual product UI. No external dependencies — RBAC and Cassandra come in later steps.

**What was added:**

- `bootstrap/namespace-thatdot-openshift.yaml` — refactored from step 1; namespace now lives in `bootstrap/` so it's shared across all steps and survives Application deletes.
- `bootstrap/application-quine-enterprise.yaml` — single-source ArgoCD Application pointing at the Kustomize root.
- `manifests/quine-enterprise/{kustomization.yaml,values.yaml,route.yaml}` — Kustomize root using `helmCharts:` to pull QE 0.5.3, render with our values, and merge an OpenShift Route.
- `scripts/create-license-secret.sh` and `scripts/create-thatdot-registry-pull-secret.sh` — idempotent helpers; called automatically by `bootstrap.sh` after preflight validation.
- `scripts/bootstrap.sh` updates: preflight env-var check; `--enable-helm` patch on the ArgoCD instance; namespace apply phase; secret-creation phase.

**Gotchas surfaced:**

1. **Moving image tags require `imagePullPolicy: Always`.** `image.tag: main` gets repointed by the registry; `IfNotPresent` would serve the kubelet's stale cache forever. Pinned semver tags can stay `IfNotPresent`.
2. **Kustomize + `helmCharts:` requires `--enable-helm` on the ArgoCD instance.** Without it, ArgoCD's Kustomize integration silently ignores the `helmCharts:` block. `bootstrap.sh` patches the ArgoCD CR.
3. **`bootstrap.sh` requires three env vars upfront** — `QE_LICENSE_KEY`, `THATDOT_REGISTRY_USERNAME`, `THATDOT_REGISTRY_PASSWORD`. Preflight collects all missing vars and reports them in one pass. Direct invocation of the secret scripts is also strict (`:?` checks).
4. **Persistor is `enabled: false` → state is in-memory only.** Pod restart wipes everything. Correct for step 2; step 3 introduces Cassandra-backed persistence.

### Step 3 — Cassandra-backed persistence (operator-managed)

**What it proves:** A stateful workload runs under OpenShift's restricted SCC posture (with one targeted relaxation), QE successfully reads/writes through to Cassandra, and **data survives a QE pod restart**. The persistence test is the actual milestone — without it, "QE talks to Cassandra" is just a connection check.

**What was added:**

- `bootstrap/cass-operator-subscription.yaml` — k8ssandra `cass-operator-community` from OperatorHub, OwnNamespace install in `thatdot-openshift`. Same Subscription idiom as the GitOps Operator install in step 1.
- `bootstrap/argocd-customizations.yaml` — single source for ArgoCD CR patches: `kustomizeBuildOptions: --enable-helm` plus a custom Lua `resourceHealthChecks` entry for `CassandraDatacenter`. Without the Lua check, ArgoCD reports the cassandra Application Healthy as soon as the CR exists; with it, Healthy means Cassandra is actually serving CQL.
- `bootstrap/application-cassandra.yaml` — single-source ArgoCD Application syncing `manifests/cassandra/`.
- `manifests/cassandra/{kustomization.yaml,cassandradatacenter.yaml,serviceaccount.yaml}` — single-node Cassandra `dc1` (cluster `quine`, 512MB heap, 2Gi PVC), plus a RoleBinding granting the namespace's `default` ServiceAccount the `anyuid` SCC (Cassandra image hardcodes UID 999, which `restricted-v2` rejects).
- `manifests/quine-enterprise/values.yaml` updates — `cassandra.enabled: true`, endpoints `quine-dc1-service:9042`, `localDatacenter: dc1`, `plaintextAuth.enabled: false` (matches Cassandra's `AllowAllAuthenticator` default).
- `manifests/quine-enterprise/patches/wait-for-cassandra.yaml` — Kustomize patch injecting an init container into the QE Deployment. Blocks QE startup until `quine-dc1-service:9042` accepts a TCP connection. Resilient to subsequent pod restarts.
- `scripts/bootstrap.sh` updates — applies any `*-operator-subscription.yaml` in `bootstrap/` (so future operators land automatically); now uses `--patch-file bootstrap/argocd-customizations.yaml` instead of inline JSON.

**Gotchas surfaced:**

1. **cass-operator hardcodes UID/GID 999** in the Cassandra pod's `securityContext`. `restricted-v2` rejects this with a verbose `unable to validate against any security context constraint` error. Fix: bind `default` ServiceAccount to the `anyuid` SCC via RoleBinding.
2. **`CassandraDatacenter.spec.serviceAccount` is effectively immutable post-creation.** cass-operator's validating webhook rejects updates: `attempted to change serviceAccount`. We initially tried directing the operator to a dedicated `cassandra-sa`, hit this, pivoted to binding the `default` SA instead. If you ever want a dedicated SA, set it on the CR's *first* apply or delete-and-recreate.
3. **cass-operator's default is `AllowAllAuthenticator`, not auth-enabled.** The auto-created `<clusterName>-superuser` Secret is provisioned defensively but isn't enforced unless you set `cassandra-yaml.authenticator: PasswordAuthenticator` on the CR. Mismatched QE auth config (`plaintextAuth.enabled: true` against a no-auth cluster) produces noisy WARN lines but functionally works. We turned QE's plaintextAuth off to match.
4. **No built-in ArgoCD health check for `CassandraDatacenter`.** Without the custom Lua check we registered, ArgoCD would report Healthy immediately on CR creation, long before Cassandra is actually serving. The check watches `cassandraOperatorProgress: Ready` plus the `Ready` condition.
5. **Init container at step 3, sync-waves added in step 4.** QE depends on Cassandra being up. At step 3 we considered app-of-apps + sync-waves but chose a pod-level init container instead — simpler, no restructuring, resilient to pod restarts. Step 4 then layered sync-waves on top via the app-of-apps refactor; the two are complementary (sync-waves order applies, init containers gate readiness). See the Conventions section.
6. **ArgoCD sync backoff after repeated failures.** When sync fails several times in a row, ArgoCD's auto-retry backs off — could be 10+ min before it tries again. After pushing a fix, use `oc annotate application <app> argocd.argoproj.io/refresh=hard --overwrite` to force an immediate re-fetch from git.

### Step 4 — App-of-apps refactor (platform/product split)

**What it proves:** the same end-state cluster as step 3, reached via a 3-level GitOps cascade rather than imperative bash loops. `bootstrap.sh` now seeds *one* `Application` (`root`) and ArgoCD owns the rest. Adding a new operator → a file in `manifests/platform/`. Adding a new workload → a file in `manifests/product/`. No `bootstrap.sh` edit, no re-running on existing clusters.

**The cascade:**

```
root (bootstrap/root-application.yaml)
 ├── application-platform   (sync-wave 0)  →  manifests/platform/
 │     ├── cass-operator-subscription      (sync-wave 0; install operator + wait for CSV)
 │     └── application-cassandra           (sync-wave 1; CRD now exists, CR creation succeeds)
 │           └── manifests/cassandra/      (CassandraDatacenter, SA + RoleBinding)
 └── application-product    (sync-wave 1)  →  manifests/product/
       └── application-quine-enterprise
             └── manifests/quine-enterprise/  (Helm chart + Route + wait-for-cassandra patch)
```

**What was added:**

- `bootstrap/root-application.yaml` — single seed Application; `path: manifests/root`; carries `resources-finalizer` so root deletion cascades through the whole tree.
- `manifests/root/{kustomization.yaml, application-platform.yaml, application-product.yaml}` — the two children of root, ordered by sync-wave annotations.
- `manifests/platform/{kustomization.yaml, cass-operator-subscription.yaml, application-cassandra.yaml}` — operator subscription + Cassandra Application, internally ordered (sub at wave 0, App at wave 1).
- `manifests/product/{kustomization.yaml, application-quine-enterprise.yaml}` — QE Application.
- New `Conventions` section at the top of this README documenting the cross-service init-container rule.

**What was removed:**

- `bootstrap/application-quine-enterprise.yaml`, `bootstrap/application-cassandra.yaml`, `bootstrap/cass-operator-subscription.yaml` — moved into `manifests/`.
- The three `for resource in bootstrap/*-foo.yaml` loops in `scripts/bootstrap.sh` — replaced by one `oc apply` of the namespace and one of the root Application.

**What stayed in `bootstrap/` and why:**

- `gitops-operator-subscription.yaml` — ArgoCD can't manage its own install.
- `argocd-customizations.yaml` — must be patched into the ArgoCD CR before the first sync runs (otherwise Kustomize+Helm renders empty and the CassandraDatacenter health check is missing).
- `namespace-thatdot-openshift.yaml` — preconditional. The OpenShift GitOps Operator watches namespaces for the `argocd.argoproj.io/managed-by` label and provisions the `RoleBinding` *asynchronously*. If we let GitOps create the namespace, the very first wrapper sync races with that RoleBinding and fails `forbidden`. Also: the secrets created by `bootstrap.sh` need the namespace to exist.
- `root-application.yaml` — the seed.

**Gotchas surfaced:**

1. **3 levels is the cap.** Codefresh's research is explicit: 4+ levels of nested Applications turns debugging into a multi-step traversal. If we ever outgrow this structure, switch the wrapper layer to ApplicationSet rather than nesting deeper.
2. **`prune: true` everywhere means deletion cascades.** Removing `application-X.yaml` from a wrapper's folder deletes that child Application *and* its workload (via `resources-finalizer`). That's the GitOps semantics, but worth knowing for "I deleted a file to test something."
3. **Sync-wave gating relies on built-in health checks.** ArgoCD's built-in checks for `argoproj.io/Application` and `operators.coreos.com/Subscription` are doing the actual gating between waves. We deliberately did *not* add custom Lua for either — only the existing `CassandraDatacenter` check from step 3. If observation showed wrappers reporting Healthy prematurely, the fallback would be Lua in `argocd-customizations.yaml`.
4. **Sync-wave inside a single Application orders *resources*, not *Applications*.** The annotations on `application-platform.yaml` and `application-product.yaml` work because, from the root Application's perspective, those are just resources it's syncing. Same trick inside `manifests/platform/` for the Subscription → application-cassandra ordering.

### Step 5 — Keycloak with the `quine-enterprise` realm

**What it proves:** the Red Hat Build of Keycloak (RHBK) operator stands up a Keycloak instance behind an edge-terminated OpenShift Route; the `quine-enterprise` realm (6 client roles, 6 interactive users, 6 service-account CLI clients) is pre-configured via a single `KeycloakRealmImport` CR; bearer tokens minted via `client_credentials` grant carry the right `iss`, `aud`, and `resource_access.<client>.roles` claims; the realm survives a Keycloak pod restart (proving Postgres persistence is wired correctly).

**The architectural shift from step 4:** Step 5 promotes the single-Application-boundary pattern to the rule for all platform stacks, and refactors Cassandra to match in the same motion. Each platform-layer leaf now owns its own operator Subscription alongside its workload CRs, wave-ordered. `oc delete application keycloak -n openshift-gitops` recreates the whole Keycloak stack from cold — the natural debug primitive when iterating on the (fire-once) realm import.

**Layout after step 5:**

```
manifests/platform/                  (only Application CRs now)
├── application-cassandra.yaml          (wave 1 — → manifests/cassandra/)
└── application-keycloak.yaml           (wave 1 — → manifests/keycloak/)

manifests/cassandra/                 (the whole Cassandra stack)
├── cass-operator-subscription.yaml     (wave 0 — moved from manifests/platform/ in step 5)
├── serviceaccount.yaml                 (wave 0 — anyuid RoleBinding)
└── cassandradatacenter.yaml            (wave 1)

manifests/keycloak/                  (the whole Keycloak stack — NEW in step 5)
├── rhbk-operator-subscription.yaml     (wave 0)
├── postgres.yaml                       (wave 1 — bare Deployment + PVC + Service)
├── keycloak.yaml                       (wave 2 — RHBK Keycloak CR)
├── route.yaml                          (wave 2 — edge-terminated Route)
└── keycloak-realm-import.yaml          (wave 3 — KeycloakRealmImport, fire-once)
```

**Realm contents (declarative, in `keycloak-realm-import.yaml`):**

- 1 interactive OIDC client `quine-enterprise-client` (browser auth-code + direct-grant flows)
- 6 client roles on it: `superadmin`, `admin`, `architect`, `dataengineer`, `analyst`, `billing`
- 6 interactive users `admin1`...`superadmin1` (placeholder passwords with `temporary: true` — Keycloak forces a reset on first login)
- 6 service-account CLI clients `qe-cli-admin`...`qe-cli-superadmin` (each with `serviceAccountsEnabled: true` and the matching client role mapped onto its service-account user — `client_credentials` grant produces a JWT with the right role)
- Every interactive user gets `realmRoles: [default-roles-quine-enterprise]`, which carries the built-in `view-profile`/`manage-account`/`offline_access`/`uma_authorization` roles needed for the Keycloak account console

All seven client secrets are **operator-generated** (never committed). Step 6 will retrieve the interactive client's secret via `kcadm.sh` and feed it into QE's OIDC config.

**The TLS-at-ingress topology:**

```
Browser ──HTTPS (cluster wildcard cert)──> OpenShift router ──HTTP──> Keycloak pod
```

`Keycloak.spec.http.httpEnabled: true` so the pod listens plain HTTP internally. `Keycloak.spec.proxy.headers: xforwarded` so Keycloak trusts `X-Forwarded-Proto: https` from the router and emits `https://...` URLs in the OIDC discovery doc and JWT `iss` claims. `Keycloak.spec.hostname.hostname` is set to the full Route URL (with `https://`) so the discovery doc's `issuer`, `authorization_endpoint`, and `token_endpoint` all match what the browser sees. This is the standard Keycloak-behind-edge-Route shape — verified by `curl`ing the discovery endpoint and confirming `issuer` starts with `https://`.

**Verification at end of step 5:**

```bash
oc get application -n openshift-gitops                 # all 6 Synced + Healthy
oc get keycloak -n thatdot-openshift                   # keycloak — Ready: True
oc get keycloakrealmimport -n thatdot-openshift        # quine-enterprise — Done: True

ROUTE=$(oc get route keycloak -n thatdot-openshift -o jsonpath='{.spec.host}')
curl -sk "https://$ROUTE/realms/quine-enterprise/.well-known/openid-configuration" | jq '.issuer'
# "https://keycloak-thatdot-openshift.apps-crc.testing/realms/quine-enterprise"

# Admin console + account console (admin user is `temp-admin` in RHBK 26.4, not `admin`)
oc get secret keycloak-initial-admin -n thatdot-openshift -o jsonpath='{.data.username}' | base64 -d ; echo
oc get secret keycloak-initial-admin -n thatdot-openshift -o jsonpath='{.data.password}' | base64 -d ; echo
open "https://$ROUTE"

# Win condition: realm + users + clients + role mappings survive Keycloak pod restart
oc delete pod keycloak-0 -n thatdot-openshift
# Wait for new pod Ready; re-run any of the above — all data persists in Postgres.
```

**What was added beyond `manifests/keycloak/`:**

- `bootstrap/argocd-customizations.yaml` gained two new `resourceHealthChecks`: `Keycloak` (Healthy when `conditions[Ready] == True` and `HasErrors == False`) and `KeycloakRealmImport` (Healthy when `conditions[Done] == True`). Without these, the `keycloak` Application would report Healthy as soon as the CRs were applied, regardless of whether the operator had finished reconciling.
- `scripts/create-keycloak-postgres-secret.sh` — idempotent secret-creation helper (random 32-char password if the Secret doesn't exist; no-op if it does). Called from `bootstrap.sh`.

**Gotchas surfaced:**

1. **OperatorHub `cloud-native-postgresql` is EDB's *commercial* product, not upstream CNPG.** It pulls from `docker.enterprisedb.com` and requires a paid pull-secret. Curated OperatorHub catalogs don't ship upstream CNPG. Pivoted to bare Postgres Deployment; if a future step wants operator-managed Postgres, `crunchy-postgres-operator` is the free alternative (different CR schema, mandatory pgBackRest).
2. **Red Hat container images with a pinned `USER` directive need `fsGroup` to write to PVCs.** `registry.redhat.io/rhel9/postgresql-16` declares `USER 26`, the namespace's `default` SA has `anyuid` (from cass-operator), so admission lands the pod under `anyuid` with UID 26 — which can't write to a freshly-mounted root-owned PVC. Fix: `securityContext: { runAsUser: 26, runAsGroup: 26, fsGroup: 26 }` in the Deployment.
3. **RHBK serves `k8s.keycloak.org/v2alpha1`, not `v2beta1`.** Upstream Keycloak Operator moved to v2beta1 in version 26; Red Hat's build (also 26.x) still serves only v2alpha1. Copy-pasting CRs from upstream docs fails at apply time with `no matches for kind "Keycloak" in version "k8s.keycloak.org/v2beta1"`. Always verify `oc get crd keycloaks.k8s.keycloak.org -o jsonpath='{.spec.versions[*].name}'` before writing CRs.
4. **CRD chicken-and-egg in single-Application leaves.** When wave 0 installs the Subscription and wave 2+ applies CRs whose CRDs that Subscription installs, ArgoCD's pre-flight dry-run fails on the CRs ("no matches for kind") *before* wave 0 gets to run, and the whole sync aborts after 5 retries. Fix: `argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true` annotation on every CRD-dependent resource (in our tree: `Keycloak`, `KeycloakRealmImport`, plus `CassandraDatacenter` post-refactor).
5. **`KeycloakRealmImport` is fire-once.** Operator marks `status.conditions[Done]: True` after the first reconcile and ignores subsequent edits to the `realm:` block. To re-import after editing the manifest: `oc delete keycloakrealmimport quine-enterprise -n thatdot-openshift` (ArgoCD recreates it on the next refresh) — or `oc delete application keycloak -n openshift-gitops` for a full stack reset. This is the *reason* the single-Application-boundary layout exists: the natural debug primitive becomes one `oc delete`.
6. **`KeycloakRealmImport` does NOT auto-assign `default-roles-<realm>` to imported users.** Users created via the admin UI get this composite automatically; imported users don't. Symptom: user logs in successfully but the account console at `/realms/<realm>/account` shows "Something went wrong" (the SPA's `userProfileMetadata` API call gets 401 because the token lacks `view-profile`). Fix: add `realmRoles: [default-roles-<realm>]` next to `clientRoles:` on every user in the realm-import YAML.
7. **RHBK 26.4 names the initial admin user `temp-admin`, not `admin`.** The `keycloak-initial-admin` Secret has both `username` and `password` keys — always read both, don't hardcode the username.
8. **`kcadm.sh get users -q username=X` is partial match by default.** Querying `username=admin1` returns BOTH `admin1` AND `superadmin1` (substring match). `tail -1` non-deterministically picks one; operations using `--uusername` silently hit the wrong user. Pair with `-q exact=true` for username lookups, or pass `--uid <UUID>` instead.
9. **ArgoCD operations can deadlock when sync-waves wait on never-Healthy resources.** If a wave-N resource enters CrashLoopBackOff, the sync operation hangs in `operationState.phase: Running` forever — and ArgoCD won't pick up new manifest edits because the current operation is still "in progress." Fix: `oc patch application <name> -n openshift-gitops --type=merge -p '{"operation":null}'`, then push your manifest fix and `argocd.argoproj.io/refresh=hard` to force an immediate retry.
10. **Resource requests on CRC are tight.** The RHBK operator's default Keycloak pod request is 1700Mi memory, and the realm-import Job inherits the same. Once Cassandra + QE + Postgres + RHBK operator are all resident, the realm-import Job pod ends up Pending with `FailedScheduling: Insufficient memory`. We explicitly set `Keycloak.spec.resources: { requests: { memory: 768Mi }, limits: { memory: 1Gi } }` to fit.
