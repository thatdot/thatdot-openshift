# thatdot-openshift

Reference deployment of [Quine Enterprise](https://www.thatdot.com/quine-enterprise) onto Red Hat OpenShift, with Cassandra as its persistor and Keycloak for OIDC-based RBAC.

> **Status:** step 3 of 5 complete — Quine Enterprise persisting through Cassandra (no RBAC yet). See [`IMPLEMENTATION_PLAN.md`](./IMPLEMENTATION_PLAN.md) for progress.

## What's here

- **[`IMPLEMENTATION_PLAN.md`](./IMPLEMENTATION_PLAN.md)** — prerequisites, step-by-step deployment plan with verification at each step, and a TL;DR checklist at the bottom.
- **[`CLAUDE.md`](./CLAUDE.md)** — context for engineers (and Claude Code) picking up the work.
- `bootstrap/` — applied directly (`oc apply`), seeds GitOps. Contains the GitOps Operator Subscription, the cass-operator Subscription, the shared `thatdot-openshift` namespace, the QE + Cassandra ArgoCD Application CRs, and the `argocd-customizations.yaml` patch (Kustomize+Helm + custom CassandraDatacenter health check).
- `manifests/quine-enterprise/` — Kustomize root sync'd by ArgoCD: pulls the QE Helm chart from `helm.thatdot.com`, renders with `values.yaml`, adds an OpenShift Route + a `wait-for-cassandra` init container patch.
- `manifests/cassandra/` — Kustomize root sync'd by ArgoCD: a `CassandraDatacenter` CR (managed by k8ssandra cass-operator) plus a RoleBinding granting the namespace's `default` SA the `anyuid` SCC.
- `scripts/` — `bootstrap.sh` (idempotent cluster bootstrap, fail-fast on missing env vars), `trust-crc-ca.sh` (browser trust), `create-license-secret.sh`, `create-thatdot-registry-pull-secret.sh`.

## Target environment

Single-node [OpenShift Local](https://developers.redhat.com/products/openshift-local) (formerly CRC) for dev iteration. Same OpenShift Container Platform bits as a production cluster.

## Architectural decisions

| | Choice |
|---|---|
| GitOps engine | OpenShift GitOps Operator (Red Hat–packaged ArgoCD) |
| In-cluster TLS | OpenShift `service-ca` (no cert-manager) |
| Cassandra auth | None (`AllowAllAuthenticator`) — out of scope for v1 |

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
oc get application -n openshift-gitops              # quine-enterprise → Synced + Healthy
ROUTE=$(oc get route quine-enterprise -n thatdot-openshift -o jsonpath='{.spec.host}')
open "https://$ROUTE"                               # browser: QE landing page (no auth in step 2)
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
5. **Init container pattern beats sync waves for cross-Application ordering.** QE depends on Cassandra being up. We considered ArgoCD app-of-apps + sync waves; chose a pod-level init container instead. Simpler, doesn't require restructuring, and resilient to pod restarts (every QE pod start re-checks Cassandra reachability).
6. **ArgoCD sync backoff after repeated failures.** When sync fails several times in a row, ArgoCD's auto-retry backs off — could be 10+ min before it tries again. After pushing a fix, use `oc annotate application <app> argocd.argoproj.io/refresh=hard --overwrite` to force an immediate re-fetch from git.
