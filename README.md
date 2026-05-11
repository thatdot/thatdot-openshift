# thatdot-openshift

Deploy [Quine Enterprise](https://www.thatdot.com/quine-enterprise) on Red Hat OpenShift — Cassandra-backed persistence, Keycloak OIDC for RBAC, all driven by OpenShift GitOps. Targets [OpenShift Local](https://developers.redhat.com/products/openshift-local) (CRC) for dev; same OpenShift bits as production.

For design rationale: [`docs/ARCHITECTURE.md`](./docs/ARCHITECTURE.md). For engineering reference (gotchas, operational notes): [`CLAUDE.md`](./CLAUDE.md).

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
crc console --credentials
oc login -u kubeadmin -p "<PASSWORD>" https://api.crc.testing:6443

# Deploy everything (idempotent — safe to re-run any time)
./scripts/bootstrap.sh

# Optional: trust the CRC ingress CA so browsers don't warn
./scripts/trust-crc-ca.sh
```

Wait ~7-10 min on first cold deploy; watch progress with `oc get application -n openshift-gitops -w` (Ctrl+C when all 6 are Synced + Healthy).

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

| Username        | QE role      | Permissions               |
| --------------- | ------------ | ------------------------- |
| `superadmin1`   | SuperAdmin   | All 34                    |
| `admin1`        | Admin        | 8                         |
| `architect1`    | Architect    | Schema + read/write       |
| `dataengineer1` | DataEngineer | Ingest + standing queries |
| `analyst1`      | Analyst      | Read-only queries         |
| `billing1`      | Billing      | License/usage UI only     |

## Iteration tips

### Shell helpers — drop in `~/.zshrc.local`

```bash
# Force a sync (resolves to spec.source.targetRevision — the branch tip).
argo-sync() { oc patch application "${1:?app}" -n openshift-gitops --type=merge \
  -p '{"operation":{"sync":{},"initiatedBy":{"username":"'"$(whoami)"'"}}}'; }

# Force a sync to your local HEAD — use when argo-sync targets a stale commit.
argo-sync-here() {
  local rev=$(git rev-parse HEAD)
  oc patch application "${1:?app}" -n openshift-gitops --type=merge \
    -p "{\"operation\":{\"sync\":{\"revision\":\"$rev\"},\"initiatedBy\":{\"username\":\"$(whoami)\"}}}"
}

argo-abort()  { oc patch application "${1:?app}" -n openshift-gitops --type=merge -p '{"operation":null}'; }
argo-status() { oc get application -n openshift-gitops "$@"; }
```

After `argo-sync`, confirm the right revision was applied:

```bash
oc get application <app> -n openshift-gitops -o jsonpath='{.status.operationState.syncResult.revision}{"\n"}'
# mismatch with `git rev-parse HEAD` → run `argo-sync-here <app>`
```

### ArgoCD UI

Same operations, with a live resource tree, diff view, and sync history. Open it from "Accessing things" above and click into an Application.

| Button | CLI equivalent |
|---|---|
| **SYNC** (tick **REVISION** in the dialog to paste a commit SHA) | `argo-sync` / `argo-sync-here` |
| **REFRESH** → "Hard Refresh" | (re-pull manifests; doesn't sync) |
| **TERMINATE** (visible during a running op) | `argo-abort` |
| **HISTORY AND ROLLBACK** | — |

The resource tree shows live status for every managed resource — click a Job to see pod logs, click a CR for the diff between git and cluster.

### Edit the Keycloak realm

Realm config lives in `manifests/keycloak/keycloak-realm-import.yaml`.

```bash
$EDITOR manifests/keycloak/keycloak-realm-import.yaml
git commit -am "add new test user" && git push
argo-sync keycloak    # or wait ~3 min for auto-drift-detection
oc get jobs -n thatdot-openshift -w   # realm-reset (PreSync) → import → pin-client-secret (PostSync)
```

PreSync wipes the old realm + CR; ArgoCD re-applies; PostSync reconciles the client_secret to the value pinned in `quine-enterprise-oidc-credentials`. **QE keeps serving throughout** — its session cookies and JWTs remain valid.

If the hook Jobs don't appear within ~30s, ArgoCD probably synced to a stale commit. Compare `syncResult.revision` to `git rev-parse HEAD` (see the helper notes above) and run `argo-sync-here keycloak`.

### Mint a bearer token for the API

Six service-account clients, one per role: `qe-cli-superadmin`, `qe-cli-admin`, `qe-cli-architect`, `qe-cli-dataengineer`, `qe-cli-analyst`, `qe-cli-billing`.

```bash
CLIENT_ID="qe-cli-admin"   # pick a role
KC_ROUTE=$(oc get route keycloak -n thatdot-openshift -o jsonpath='{.spec.host}')
QE_ROUTE=$(oc get route quine-enterprise -n thatdot-openshift -o jsonpath='{.spec.host}')
KC_POD=$(oc get pod -n thatdot-openshift -l app=keycloak -o jsonpath='{.items[0].metadata.name}')
ADMIN_USER=$(oc get secret keycloak-initial-admin -n thatdot-openshift -o jsonpath='{.data.username}' | base64 -d)
ADMIN_PW=$(oc get secret keycloak-initial-admin -n thatdot-openshift -o jsonpath='{.data.password}' | base64 -d)

oc exec -n thatdot-openshift "$KC_POD" -- env ADMIN_PW="$ADMIN_PW" /bin/bash -c \
  "/opt/keycloak/bin/kcadm.sh config credentials --server http://localhost:8080 --realm master --user $ADMIN_USER --password \"\$ADMIN_PW\"" >/dev/null
CID=$(oc exec -n thatdot-openshift "$KC_POD" -- /opt/keycloak/bin/kcadm.sh get clients -r quine-enterprise -q exact=true -q "clientId=$CLIENT_ID" --fields id --format csv --noquotes | tail -1 | tr -d '\r')
CLI_SECRET=$(oc exec -n thatdot-openshift "$KC_POD" -- /opt/keycloak/bin/kcadm.sh get "clients/$CID/client-secret" -r quine-enterprise --fields value --format csv --noquotes | tail -1 | tr -d '\r')

TOKEN=$(curl -sk -d "client_id=$CLIENT_ID" -d "client_secret=$CLI_SECRET" -d "grant_type=client_credentials" \
  "https://$KC_ROUTE/realms/quine-enterprise/protocol/openid-connect/token" | jq -r .access_token)
curl -sk -H "Authorization: Bearer $TOKEN" "https://$QE_ROUTE/api/v2/auth/me" | jq
```

### Inspect a user's access token shape

Keycloak's admin console has a "Generated access token" tool — shows the JWT payload it would mint for a user, with no curl or password needed.

Open the Keycloak admin console (see "Accessing things"), then: realm switcher → **`quine-enterprise`** → **Clients** → `quine-enterprise-client` → **Client scopes** → **Evaluate** → pick a user → **"Generated access token"**.

Verify `roles` is at the **top level** of the JWT (not nested under `resource_access.*`) and contains the exact PascalCase value(s) for that user (`SuperAdmin`, `Admin`, etc. — case-sensitive).

### Reset a single workload

```bash
oc delete application keycloak -n openshift-gitops          # full Keycloak stack cold (~5-7 min)
oc delete application quine-enterprise -n openshift-gitops  # QE cold
oc delete application cassandra -n openshift-gitops         # WIPES DATA — PVC GC'd via resources-finalizer
```

The parent Application's drift detection recreates the child within ~30s. Force with `argo-sync root` if impatient.

For routine realm edits, prefer the GitOps flow above — `oc delete application keycloak` is the heavy hammer.

### Nuke everything

```bash
oc delete application root -n openshift-gitops    # cascades through the whole tree
oc delete namespace thatdot-openshift
./scripts/bootstrap.sh                            # rebuild
```

Or fully fresh cluster: `crc delete && crc start ...` then re-run bootstrap.

## Diagnostics

```bash
oc get application -n openshift-gitops                                            # sync + health per Application
oc get pods -n thatdot-openshift                                                  # pod status across the deployment
oc logs -n thatdot-openshift -l app=quine-enterprise --tail=100                   # QE
oc logs -n thatdot-openshift -l app=keycloak --tail=100                           # Keycloak
oc logs -n thatdot-openshift -l app.kubernetes.io/instance=quine-dc1 --tail=100   # Cassandra
oc describe pod -n thatdot-openshift <pod-name>                                   # init-container errors, SCC denials
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

Repository is public. No license keys, admin passwords, or TLS private material are committed — secrets flow in at deploy time via env vars + `oc create secret`.
