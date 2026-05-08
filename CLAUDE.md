# Claude Code context — thatdot-openshift

## What this is

Discovery + first implementation pass to deploy Quine Enterprise into Red Hat OpenShift, on a local OpenShift Local (formerly CRC) cluster. Tracking ticket: **[QU-2539](https://thatdot.atlassian.net/browse/QU-2539)**.

The canonical document is **[`IMPLEMENTATION_PLAN.md`](./IMPLEMENTATION_PLAN.md)** — read it first. It has prerequisites, a 5-step walking-skeleton plan with verification per step, and a TL;DR checklist at the bottom that tracks progress.

## Critical rules

- **This repo is public on GitHub.** Never commit license keys, admin passwords, customer details, internal cluster URLs, or TLS private material. Secrets flow in via env vars at deploy time → `oc create secret`. Manifests reference secrets by name only.
- **OpenShift-native lane is the deliberate choice.** When recommending tooling or patterns, default to OpenShift-native equivalents (Operators from OperatorHub, Routes, `service-ca`, OpenShift GitOps) rather than upstream patterns from `enterprise-oauth-reference`.
- **Manifest-driven, not UI-driven.** All cluster state — operator Subscriptions, Namespaces, ArgoCD Applications, RoleBindings, everything — is expressed as YAML in this repo and applied via `oc apply` (for `bootstrap/` items) or GitOps sync (for `manifests/`). The OperatorHub web console is a *discovery* tool only; never install something through clicks without committing the resulting manifest. This is what makes the eventual production deployment reproducible from a clone.
- **Semantic naming, not step-numbered.** Files and directories are named by what they *are*, not by which step introduced them. `application-quine-enterprise.yaml`, `manifests/quine-enterprise/`, `manifests/cassandra/`, etc. Step numbers live in branch names (`step-2-basic-qe`) and the `IMPLEMENTATION_PLAN.md`, never in repo paths. (Step 1 used `step-1` paths; that was a v1 mistake corrected during step 2.)
- **Walking-skeleton order matters.** Don't skip ahead from step N to step N+2. Each step's verification is the gate for the next.

## Architectural decisions (locked in)

| Decision | Choice | Rationale |
|---|---|---|
| Local cluster | OpenShift Local (CRC) | Same OCP bits as a production OpenShift cluster |
| GitOps engine | OpenShift GitOps Operator | Red Hat–native; the standard OpenShift GitOps path |
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

## File layout (will grow as work progresses)

```
IMPLEMENTATION_PLAN.md       # canonical plan + checklist (start here)
README.md                    # external-facing entry point
CLAUDE.md                    # this file
.gitignore                   # secret-shaped patterns blocked
.pre-commit-config.yaml      # gitleaks hook
bootstrap/                   # Applied directly with `oc apply` (NOT GitOps-synced)
  gitops-operator-subscription.yaml   # OpenShift GitOps Operator install
  namespace-thatdot-openshift.yaml    # shared workload namespace (also has the managed-by label)
  application-quine-enterprise.yaml   # ArgoCD Application — QE
  application-cassandra.yaml          # (step 3, future)
  application-keycloak.yaml           # (step 4, future)
manifests/                   # GitOps-synced by Application CRs (Kustomize roots)
  quine-enterprise/          # QE Helm chart + values + Route + future patches
    kustomization.yaml       #   helmCharts: + resources: + (later) patches:
    values.yaml              #   QE Helm values
    route.yaml               #   OpenShift Route (chart doesn't ship one)
  cassandra/                 # (step 3, future)
  keycloak/                  # (step 4, future)
scripts/                     # Helper scripts (idempotent)
  bootstrap.sh               # Install GitOps + apply Application CRs
  trust-crc-ca.sh            # Trust CRC ingress CA in macOS keychain (Chrome/Safari)
  create-license-secret.sh   # $QE_LICENSE_KEY → qe-license Secret
  create-thatdot-registry-pull-secret.sh   # $THATDOT_REGISTRY_* → thatdot-registry-creds Secret
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

## When you finish a piece of work

- Update `IMPLEMENTATION_PLAN.md`: cross off the relevant TL;DR checklist item; if you diverged from the plan, edit the affected step rather than letting the plan drift.
- Add the corresponding section to `README.md` so the README is a real walk-through, not a stub.
- Verify nothing secret-shaped is staged before committing (`git diff --cached`).
