# thatdot-openshift

Reference deployment of [Quine Enterprise](https://www.thatdot.com/quine-enterprise) onto Red Hat OpenShift, with Cassandra as its persistor and Keycloak for OIDC-based RBAC.

> **Status:** step 2 of 5 complete — Quine Enterprise running standalone (no persistor, no RBAC). See [`IMPLEMENTATION_PLAN.md`](./IMPLEMENTATION_PLAN.md) for progress.

## What's here

- **[`IMPLEMENTATION_PLAN.md`](./IMPLEMENTATION_PLAN.md)** — prerequisites, step-by-step deployment plan with verification at each step, and a TL;DR checklist at the bottom.
- **[`CLAUDE.md`](./CLAUDE.md)** — context for engineers (and Claude Code) picking up the work.
- `bootstrap/` — applied directly (`oc apply`), seeds GitOps. Contains the GitOps Operator Subscription, the shared `thatdot-openshift` namespace, and the QE ArgoCD Application CR.
- `manifests/quine-enterprise/` — Kustomize root sync'd by ArgoCD: pulls the QE Helm chart from `helm.thatdot.com`, renders with `values.yaml`, adds an OpenShift Route.
- `scripts/` — `bootstrap.sh` (idempotent cluster bootstrap, fail-fast on missing env vars), `trust-crc-ca.sh` (browser trust), `create-license-secret.sh`, `create-thatdot-registry-pull-secret.sh`.

## Target environment

Single-node [OpenShift Local](https://developers.redhat.com/products/openshift-local) (formerly CRC) for dev iteration. Same OpenShift Container Platform bits as a production cluster.

## Architectural decisions

| | Choice |
|---|---|
| GitOps engine | OpenShift GitOps Operator (Red Hat–packaged ArgoCD) |
| In-cluster TLS | OpenShift `service-ca` (no cert-manager) |
| Cassandra auth | Plaintext (out of scope for v1) |

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
