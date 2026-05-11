# thatdot-openshift

Deploy [Quine Enterprise](https://www.thatdot.com/quine-enterprise) on Red Hat OpenShift — Cassandra-backed persistence, Keycloak OIDC for RBAC, all driven by OpenShift GitOps. Targets [OpenShift Local](https://developers.redhat.com/products/openshift-local) (CRC) for dev; same OpenShift bits as production.

For design rationale (why these choices, per-stack briefs, known gaps for production): see [`docs/ARCHITECTURE.md`](./docs/ARCHITECTURE.md). For engineering reference (gotchas, operational notes): see [`CLAUDE.md`](./CLAUDE.md).

## Prerequisites

- macOS or Linux
- `crc` + `oc` ([OpenShift Local install](https://developers.redhat.com/products/openshift-local))
- Red Hat developer account (free) for the CRC pull secret
- Three env vars (suggested home: `~/.zshrc.local`):

```bash
export QE_LICENSE_KEY="..."
export THATDOT_REGISTRY_USERNAME="..."
export THATDOT_REGISTRY_PASSWORD="..."
```

## First-time setup

```bash
# Configure & start CRC (one-time)
crc setup
crc config set memory 18432    # 18GB recommended — 16GB is the floor
crc config set cpus 6
crc config set disk-size 60
crc start --pull-secret-file ~/Downloads/pull-secret.txt

# Log in (every shell)
eval "$(crc oc-env)"
oc login -u kubeadmin -p "$(crc console --credentials | awk '/kubeadmin/{print $NF}' | tr -d \")" https://api.crc.testing:6443

# Deploy everything (idempotent — safe to re-run any time)
./scripts/bootstrap.sh

# Optional: trust the CRC ingress CA so browsers don't warn
./scripts/trust-crc-ca.sh
```

Wait ~7-10 min on first cold deploy; watch progress with:

```bash
oc get application -n openshift-gitops -w   # Ctrl+C when all 6 are Synced + Healthy
```

## Accessing things

```bash
# Quine Enterprise (log in as superadmin1 / placeholder123 → forced password reset)
open "https://$(oc get route quine-enterprise -n thatdot-openshift -o jsonpath='{.spec.host}')"

# Keycloak admin console — initial admin in RHBK 26.4 is `temp-admin`, not `admin`
oc get secret keycloak-initial-admin -n thatdot-openshift -o jsonpath='{.data.username}' | base64 -d; echo
oc get secret keycloak-initial-admin -n thatdot-openshift -o jsonpath='{.data.password}' | base64 -d; echo
open "https://$(oc get route keycloak -n thatdot-openshift -o jsonpath='{.spec.host}')"

# ArgoCD UI (log in via "LOG IN VIA OPENSHIFT" with kubeadmin)
open "https://$(oc get route openshift-gitops-server -n openshift-gitops -o jsonpath='{.spec.host}')"
```

## Built-in test users

Six interactive users, one per role. All have initial password `placeholder123` (forced reset on first login).

| Username | QE role | Permissions |
|---|---|---|
| `superadmin1` | SuperAdmin | All 34 |
| `admin1` | Admin | 8 |
| `architect1` | Architect | Schema + read/write |
| `dataengineer1` | DataEngineer | Ingest + standing queries |
| `analyst1` | Analyst | Read-only queries |
| `billing1` | Billing | License/usage UI only |

## Iteration tips

### Shell helpers — drop in `~/.zshrc.local`

```bash
# Force a sync immediately (resets ArgoCD's retry-backoff)
argo-sync() { oc patch application "${1:?app}" -n openshift-gitops --type=merge \
  -p '{"operation":{"sync":{"revision":"HEAD"},"initiatedBy":{"username":"'"$(whoami)"'"}}}'; }

# Cancel a stuck sync ("operationState.phase: Running" forever)
argo-abort() { oc patch application "${1:?app}" -n openshift-gitops --type=merge -p '{"operation":null}'; }

# Status across all Apps
argo-status() { oc get application -n openshift-gitops "$@"; }
```

Note: `argocd.argoproj.io/refresh=hard` only re-pulls manifests — it does NOT force a sync and does NOT reset retry-backoff. Use `argo-sync` for that.

### Edit the Keycloak realm

Realm config lives in `manifests/keycloak/keycloak-realm-import.yaml`. Edits are GitOps-driven with automated re-import:

```bash
$EDITOR manifests/keycloak/keycloak-realm-import.yaml
git commit -am "add new test user"
git push
argo-sync keycloak    # or wait ~3 min for ArgoCD's drift detection
```

A PreSync hook deletes the realm + CR, ArgoCD re-applies, and a PostSync hook reconciles the client_secret back to the value pinned in the `quine-enterprise-oidc-credentials` Secret. **QE keeps serving throughout** — its session cookies and JWTs remain valid.

Watch the hooks:

```bash
oc get jobs -n thatdot-openshift -w    # realm-reset (PreSync) then pin-client-secret (PostSync)
```

### Mint a bearer token for the API

Six pre-provisioned service-account CLI clients, one per role: `qe-cli-superadmin`, `qe-cli-admin`, `qe-cli-architect`, `qe-cli-dataengineer`, `qe-cli-analyst`, `qe-cli-billing`.

```bash
CLIENT_ID="qe-cli-admin"   # pick a role
KC_ROUTE=$(oc get route keycloak -n thatdot-openshift -o jsonpath='{.spec.host}')
QE_ROUTE=$(oc get route quine-enterprise -n thatdot-openshift -o jsonpath='{.spec.host}')
KC_POD=$(oc get pod -n thatdot-openshift -l app=keycloak -o jsonpath='{.items[0].metadata.name}')
ADMIN_USER=$(oc get secret keycloak-initial-admin -n thatdot-openshift -o jsonpath='{.data.username}' | base64 -d)
ADMIN_PW=$(oc get secret keycloak-initial-admin -n thatdot-openshift -o jsonpath='{.data.password}' | base64 -d)

# Extract the client secret via kcadm
oc exec -n thatdot-openshift "$KC_POD" -- env ADMIN_PW="$ADMIN_PW" /bin/bash -c \
  "/opt/keycloak/bin/kcadm.sh config credentials --server http://localhost:8080 --realm master --user $ADMIN_USER --password \"\$ADMIN_PW\"" >/dev/null
CID=$(oc exec -n thatdot-openshift "$KC_POD" -- /opt/keycloak/bin/kcadm.sh get clients -r quine-enterprise -q exact=true -q "clientId=$CLIENT_ID" --fields id --format csv --noquotes | tail -1 | tr -d '\r')
CLI_SECRET=$(oc exec -n thatdot-openshift "$KC_POD" -- /opt/keycloak/bin/kcadm.sh get "clients/$CID/client-secret" -r quine-enterprise --fields value --format csv --noquotes | tail -1 | tr -d '\r')

# Mint the token
TOKEN=$(curl -sk -d "client_id=$CLIENT_ID" -d "client_secret=$CLI_SECRET" -d "grant_type=client_credentials" \
  "https://$KC_ROUTE/realms/quine-enterprise/protocol/openid-connect/token" | jq -r .access_token)

# Use it
curl -sk -H "Authorization: Bearer $TOKEN" "https://$QE_ROUTE/api/v2/auth/me" | jq
```

### Reset a single workload

The single-Application-boundary layout means each stack is independently resettable:

```bash
# Recreate the whole Keycloak stack cold (operator + Postgres + Keycloak + realm)
# Note: prefer the realm-edit + commit flow above for routine realm changes.
oc delete application keycloak -n openshift-gitops      # ~5-7 min full cycle

# Same for QE
oc delete application quine-enterprise -n openshift-gitops

# Cassandra (WIPES DATA — PVC is GC'd by ArgoCD's resources-finalizer)
oc delete application cassandra -n openshift-gitops
```

After a delete, the parent Application's drift detection recreates the child within ~30s. Force with `argo-sync root` if impatient.

### Nuke everything

```bash
oc delete application root -n openshift-gitops    # cascades through the whole tree
oc delete namespace thatdot-openshift
./scripts/bootstrap.sh                            # rebuild
```

Or fully fresh cluster: `crc delete && crc start ...` then re-run bootstrap.

## Diagnostics

```bash
# Application sync + health status
oc get application -n openshift-gitops

# Pod status across the deployment namespace
oc get pods -n thatdot-openshift

# Logs from a specific workload
oc logs -n thatdot-openshift -l app=quine-enterprise --tail=100
oc logs -n thatdot-openshift -l app=keycloak --tail=100
oc logs -n thatdot-openshift -l app.kubernetes.io/instance=quine-dc1 --tail=100  # Cassandra

# Inspect a failing pod (init container errors, SCC denials, etc.)
oc describe pod -n thatdot-openshift <pod-name>
```

## Layout

```
bootstrap/         # Applied imperatively by bootstrap.sh — things GitOps can't manage itself.
manifests/         # GitOps-synced (app-of-apps): root → platform + product → leaves.
  cassandra/         # cass-operator + CassandraDatacenter
  keycloak/          # RHBK operator + Postgres + Keycloak CR + realm + Pre/PostSync hooks
  quine-enterprise/  # QE Helm chart + Route + init containers
scripts/           # Idempotent helpers called by bootstrap.sh
docs/              # Customer-facing artifacts
```

## Public-repo notice

This repository is public. **No license keys, admin passwords, or TLS private material are committed.** Secrets flow in at deploy time via env vars + `oc create secret`.
