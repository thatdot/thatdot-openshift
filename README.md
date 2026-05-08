# thatdot-openshift

Reference deployment of [Quine Enterprise](https://www.thatdot.com/quine-enterprise) onto Red Hat OpenShift, with Cassandra as its persistor and Keycloak for OIDC-based RBAC.

> **Status:** step 1 of 5 complete — Hello, OpenShift (nginx via GitOps + Route). See [`IMPLEMENTATION_PLAN.md`](./IMPLEMENTATION_PLAN.md) for progress.

## What's here

- **[`IMPLEMENTATION_PLAN.md`](./IMPLEMENTATION_PLAN.md)** — prerequisites, step-by-step deployment plan with verification at each step, and a TL;DR checklist at the bottom.
- **[`CLAUDE.md`](./CLAUDE.md)** — context for engineers (and Claude Code) picking up the work.
- `bootstrap/` — manifests applied directly (`oc apply`); the seed for GitOps. Currently: GitOps Operator Subscription + the step-1 ArgoCD Application CR.
- `manifests/step-1/` — GitOps-synced nginx workload + namespace.
- `scripts/` — `bootstrap.sh` (idempotent cluster bootstrap) + `trust-crc-ca.sh` (browser trust for the CRC ingress CA).

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

## Steps so far

### Step 1 — Hello, OpenShift

**What this step proves:** the full GitOps loop end-to-end. GitHub → OpenShift GitOps Operator → ArgoCD → manifest sync → OpenShift Route → browser. nginx is the workload; the *loop* is the discovery. Every subsequent step rides on this same infrastructure.

**Reproduce on a fresh CRC cluster:**

```bash
# 1. Start your cluster (see IMPLEMENTATION_PLAN.md prerequisites for first-time setup)
crc start --pull-secret-file ~/Downloads/pull-secret.txt
eval "$(crc oc-env)"
oc login -u kubeadmin -p <pw> https://api.crc.testing:6443    # `crc console --credentials` for pw

# 2. (Optional) trust the CRC ingress CA so browsers don't warn
./scripts/trust-crc-ca.sh

# 3. Bootstrap GitOps and seed the step-1 Application
./scripts/bootstrap.sh
```

`bootstrap.sh` is idempotent — it applies `bootstrap/gitops-operator-subscription.yaml`, waits for ArgoCD, then applies every `bootstrap/application-*.yaml` (currently just `application-step-1.yaml`). Re-run any time.

**Verify:**

```bash
# ArgoCD reports Synced + Healthy
oc get application step-1 -n openshift-gitops -w

# Browser sees the nginx welcome page
ROUTE=$(oc get route nginx -n thatdot-openshift -o jsonpath='{.spec.host}')
open "https://$ROUTE"
```

**Two real gotchas surfaced by this step** (both apply to every workload that follows):

1. **Non-root container image required.** OpenShift's `restricted-v2` SCC assigns a random UID and forbids binding ports below 1024. The standard `nginx:latest` runs as root and binds port 80, so it crashloops here. We use `nginxinc/nginx-unprivileged:latest` which binds 8080 as a non-root user. Helm charts that pin `runAsUser` will need that field stripped.
2. **Target namespace must carry the `argocd.argoproj.io/managed-by` label.** OpenShift GitOps's default ArgoCD instance is namespace-scoped and can only manage resources in `openshift-gitops` until granted permissions elsewhere. Adding `argocd.argoproj.io/managed-by: openshift-gitops` to a namespace's labels tells the operator to provision the RoleBinding automatically. Without it, sync fails with "forbidden" on every resource.
