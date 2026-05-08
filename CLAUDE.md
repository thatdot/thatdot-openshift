# Claude Code context — thatdot-openshift

## What this is

Discovery + first implementation pass to deploy Quine Enterprise into Red Hat OpenShift, on a local OpenShift Local (formerly CRC) cluster. Customer driver: Wells Fargo PoC. Tracking ticket: **[QU-2539](https://thatdot.atlassian.net/browse/QU-2539)**.

The canonical document is **[`IMPLEMENTATION_PLAN.md`](./IMPLEMENTATION_PLAN.md)** — read it first. It has prerequisites, a 5-step walking-skeleton plan with verification per step, and a TL;DR checklist at the bottom that tracks progress.

## Critical rules

- **This repo is public on GitHub.** Never commit license keys, admin passwords, customer details, internal cluster URLs, or TLS private material. Secrets flow in via env vars at deploy time → `oc create secret`. Manifests reference secrets by name only.
- **OpenShift-native lane is the deliberate choice.** When recommending tooling or patterns, default to OpenShift-native equivalents (Operators from OperatorHub, Routes, `service-ca`, OpenShift GitOps) rather than upstream patterns from `enterprise-oauth-reference`.
- **Manifest-driven, not UI-driven.** All cluster state — operator Subscriptions, Namespaces, ArgoCD Applications, RoleBindings, everything — is expressed as YAML in this repo and applied via `oc apply` (for `bootstrap/` items) or GitOps sync (for `manifests/`). The OperatorHub web console is a *discovery* tool only; never install something through clicks without committing the resulting manifest. This is what makes Wells Fargo's eventual deployment reproducible from a clone.
- **Walking-skeleton order matters.** Don't skip ahead from step N to step N+2. Each step's verification is the gate for the next.

## Architectural decisions (locked in)

| Decision | Choice | Rationale |
|---|---|---|
| Local cluster | OpenShift Local (CRC) | Same OCP bits Wells Fargo runs |
| GitOps engine | OpenShift GitOps Operator | Red Hat–native; what Wells Fargo will use |
| TLS source | OpenShift `service-ca` (in-cluster) + default Route edge cert | Zero-install; no PEM material in public repo |
| Cassandra auth | Plaintext `PasswordAuthenticator` | Out of v1 scope; defer JWT auth |
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

# Diagnostics
oc get pods -A | grep -E "thatdot-openshift|gitops|operators"
oc describe pod -n thatdot-openshift <pod> | grep -E "scc|runAsUser|Status"
oc logs -n thatdot-openshift -l app=<label>
oc get application -n openshift-gitops
oc get csv -n openshift-operators

# Secrets (out-of-band)
oc create secret generic qe-license --from-literal=license-key="$QE_LICENSE_KEY"
```

## File layout (will grow as work progresses)

```
IMPLEMENTATION_PLAN.md       # canonical plan + checklist (start here)
README.md                    # external-facing entry point
CLAUDE.md                    # this file
.gitignore                   # secret-shaped patterns blocked
.pre-commit-config.yaml      # gitleaks hook
bootstrap/                   # Applied directly with `oc apply` (NOT GitOps-synced)
  gitops-operator-subscription.yaml  # one-time, step-1
  application-*.yaml                 # ArgoCD Application CR per step; seeds each sync
manifests/                   # GitOps-synced by the Application CRs
  step-1/                    # namespace + nginx + Route
  step-2/                    # QE standalone
  step-3/                    # + Cassandra
  step-4/                    # + Keycloak realm
  step-5/                    # + RBAC wiring
```

## Useful gotchas (from `enterprise-oauth-reference`)

- QE resource limits: `2Gi` request, `4Gi` limit, `-Xmx2g`. Without these, JVM uses 25% of node RAM and OOM-kills.
- Cassandra heap: cap to `512m` — CRC has limited memory.
- `--force-config` flag on QE so it uses YAML persistor config rather than the recipe's default ephemeral RocksDB.
- QE OIDC library (`oidc4s`) requires `https://` for the issuer URL — non-negotiable. `service-ca` handles this for in-cluster TLS.
- OpenShift `restricted-v2` SCC assigns a *random* UID. Helm charts pinning `runAsUser` will be rejected. Strip the field; let SCC pick.
- Cassandra datacenter name is taken from the CR's `metadata.name` — keep Helm values' `cassandra.localDatacenter` aligned.

## When you finish a piece of work

- Update `IMPLEMENTATION_PLAN.md`: cross off the relevant TL;DR checklist item; if you diverged from the plan, edit the affected step rather than letting the plan drift.
- Add the corresponding section to `README.md` so the README is a real walk-through, not a stub.
- Verify nothing secret-shaped is staged before committing (`git diff --cached`).
