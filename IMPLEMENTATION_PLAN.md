# Implementation Plan: Quine Enterprise on OpenShift

Tracking ticket: **[QU-2539](https://thatdot.atlassian.net/browse/QU-2539)** — Deploy Quine Enterprise w/ Cassandra in OpenShift. Discovery + first implementation pass for the Wells Fargo PoC.

## Strategy

Walking-skeleton approach. Each step adds *exactly one* unknown so failures have a single possible cause. Each step ends with a verifiable success criterion before the next begins. The README accretes alongside the manifests — every step contributes a section.

## Architectural decisions (locked in)

- **Local cluster:** OpenShift Local (formerly CRC) — single-node OCP in a VM. Same OCP bits Wells Fargo runs.
- **GitOps engine:** OpenShift GitOps Operator (Red Hat–packaged ArgoCD). Installed via OperatorHub; manages ArgoCD as an `ArgoCD` CR.
- **TLS source:** OpenShift `service-ca` for in-cluster service-to-service TLS; cluster default wildcard cert for Routes. No cert-manager, no PEM material in repo.
- **Repo visibility:** **Public** GitHub repo. No license keys, admin passwords, customer details, or TLS private material in commits — ever.

## Prerequisites

### Tools to install (macOS)

| Tool | Install | Verify |
|---|---|---|
| `crc` (OpenShift Local) | Download from [developers.redhat.com/products/openshift-local](https://developers.redhat.com/products/openshift-local) | `crc version` |
| `oc` (OpenShift CLI) | Bundled with CRC, or `brew install openshift-cli` | `oc version --client` |
| `helm` | `brew install helm` | `helm version` |
| `git` | Comes with macOS / Xcode CLT | `git --version` |
| `gitleaks` | `brew install gitleaks` | `gitleaks version` |
| `pre-commit` | `brew install pre-commit` | `pre-commit --version` |

### Accounts / external

- **Red Hat developer account** — required to download the CRC pull secret. Free at [console.redhat.com](https://console.redhat.com).
- **GitHub repo** — public, under `thatdot/thatdot-openshift` (or chosen name). Needs to be reachable by OpenShift GitOps for the Application sync.
- **License keys** — `QE_LICENSE_KEY` exported in the shell when needed. Never committed.

### Environment setup

```bash
# One-time CRC setup
crc setup
crc config set memory 16384      # 16 GB minimum for QE + Cassandra + Keycloak
crc config set cpus 6            # adjust to your machine
crc config set disk-size 60      # GB

# Start the cluster (downloads ~5 GB the first time)
crc start --pull-secret-file ~/Downloads/pull-secret.txt

# Wire `oc` onto your PATH (one-time per shell)
eval "$(crc oc-env)"

# Print the login commands for both kubeadmin (cluster-admin) and developer
crc console --credentials

# Copy the kubeadmin `oc login -u kubeadmin -p ... https://api.crc.testing:6443`
# command from the output above and run it. Then verify:
oc whoami    # should return kubeadmin
```

### Repo safety nets (do this before the first commit)

- `.gitignore` excluding `.env`, `.env.*`, `*.key`, `*.pem`, `*.p12`, `*.jks`, `secrets/`, `*-license-secret.yaml`, `kubeconfig`
- `pre-commit install` with `gitleaks` hook in `.pre-commit-config.yaml`
- README discloses required env vars; never their values

---

## Step-by-step

### Step 1 — OpenShift Project + GitOps Operator + nginx via Route

**Goal:** Prove the full deployment loop (GitHub → OpenShift GitOps → manifest sync → Route → browser) works on a known-good workload before introducing any product complexity.

**What's added**
- OpenShift Project: `thatdot-openshift`
- OpenShift GitOps Operator subscription (cluster-scoped, via OperatorHub)
- An ArgoCD `Application` CR pointing at `manifests/step-1/` in this repo
- `manifests/step-1/`: nginx Deployment + Service + Route

**Verification**

```bash
oc get csv -n openshift-operators | grep gitops             # Succeeded
oc get pods -n openshift-gitops                             # argocd-* pods Running
oc get application -n openshift-gitops                      # Synced + Healthy
oc get pods -n thatdot-openshift                            # nginx Running
oc describe pod -n thatdot-openshift -l app=nginx | grep scc  # restricted-v2
oc get route -n thatdot-openshift                           # HOST/PORT visible
curl -k "https://$(oc get route nginx -n thatdot-openshift -o jsonpath='{.spec.host}')"  # nginx welcome HTML
```

**Done when** the Route URL serves the nginx welcome page in a browser, and the GitOps Application reports Synced + Healthy.

**README addendum** "Step 1: Hello, OpenShift" — install commands, verification, what you've just proved.

---

### Step 2 — Quine Enterprise alone (default RocksDB, no RBAC)

**Goal:** QE running on OpenShift with no external dependencies. Isolates QE-specific issues (image, SCC compatibility, JVM args) from data and auth concerns.

**Pre-step (out-of-band, no commit)**

```bash
oc create secret generic qe-license \
  --from-literal=license-key="$QE_LICENSE_KEY" \
  -n thatdot-openshift
```

**What's added**
- `manifests/step-2/`: QE Helm overlay or Kustomize with:
  - Default in-memory / RocksDB persistor (no Cassandra config yet)
  - No OIDC config (`-Dquine.oidc.enabled=false` or omitted)
  - Resource: `2Gi` request / `4Gi` limit; `-Xmx2g` to cap JVM heap
  - License key sourced from `qe-license` Secret
  - Route exposing QE UI

**SCC trap to watch:** OpenShift's `restricted-v2` SCC assigns a *random* UID. If the QE Helm chart pins `runAsUser`, the pod will be rejected. Fix: remove `runAsUser` from the pod spec and let SCC pick.

**Verification**

```bash
oc get pods -n thatdot-openshift -l app=quine-enterprise         # Running, Ready 1/1
oc describe pod -n thatdot-openshift -l app=quine-enterprise | grep -E '(scc|runAsUser)'
oc logs -n thatdot-openshift -l app=quine-enterprise | grep -i "started\|listening"
# Browser: hit the QE Route, log in (no RBAC), run:
#   CREATE (n:Test {name: 'hello'}) RETURN n
# Confirm the node is returned. Refresh — node persists in-memory.
```

**Done when** the QE UI is reachable via Route and a Cypher query round-trips against in-memory state.

**README addendum** "Step 2: Quine Enterprise standalone."

---

### Step 3 — Add Cassandra; switch QE persistor

**Goal:** Verify a stateful workload runs under restricted SCC and QE can use Cassandra as its persistor.

**What's added**
- `manifests/step-3/cassandra/`: single-node Cassandra (StatefulSet + headless Service + PVC). Heap capped (`MAX_HEAP_SIZE=512m`) to fit CRC.
- QE config update: `quine.store.type=cassandra`, endpoints, datacenter name, `--force-config` flag (so QE uses the values-file persistor config, not the recipe default)
- PVC against the default OpenShift Local StorageClass

**SCC traps to watch**
- Cassandra image may pin `runAsUser` — remove it
- Data dir permissions: PVC mount UID may not match container's expected UID under random-UID SCC. Use `fsGroup` carefully or pick an image that respects arbitrary UIDs (k8ssandra images do).

**Verification**

```bash
oc get pods -n thatdot-openshift -l app=cassandra                # Running, Ready 1/1
oc exec -n thatdot-openshift cassandra-0 -- cqlsh -e "DESCRIBE KEYSPACES"
oc logs -n thatdot-openshift -l app=quine-enterprise | grep -i cassandra | grep -i "connect\|established"
# Browser: in QE, create a node, then:
oc delete pod -n thatdot-openshift -l app=quine-enterprise       # restart QE
# Browser: query for the node — it should still be there (proves persistence)
oc exec -n thatdot-openshift cassandra-0 -- cqlsh -e "DESCRIBE KEYSPACES"  # quine keyspace exists
```

**Done when** a Cypher write survives a QE pod restart, and the data is observable in Cassandra via `cqlsh`.

**README addendum** "Step 3: Cassandra-backed persistence."

---

### Step 4 — Add Keycloak with `quine-enterprise` realm

**Goal:** Stand up Keycloak with the realm pre-configured, *before* wiring QE to it. Isolates Keycloak issues from OIDC-integration issues.

**What's added**
- `manifests/step-4/keycloak/`: Keycloak Deployment (or RHBK Operator from OperatorHub — decide during the step), PostgreSQL for Keycloak storage, realm import (Job using `keycloak-config-cli`, or `KeycloakRealmImport` CR if using the operator)
- Realm config (port from `../opstools/keycloak/k8s/realm.json`):
  - 1 client: `quine-enterprise`
  - 6 roles: `superadmin`, `admin`, `architect`, `dataengineer`, `analyst`, `billing`
  - 6 test users with matching passwords (placeholders ok in v1; rotate before any sharing)
- Keycloak Service annotated with `service.beta.openshift.io/serving-cert-secret-name` so OpenShift mints the TLS cert
- Route exposing the Keycloak admin console

**Verification**

```bash
oc get pods -n thatdot-openshift -l app=keycloak                 # Running, Ready 1/1
oc get secret keycloak-tls -n thatdot-openshift                  # service-ca-minted cert exists
# Browser: hit the Keycloak Route, log in to admin console with the auto-generated admin secret
# Confirm: 'quine-enterprise' realm visible, 6 users, 6 roles
# Browser: log in as test user via the realm's account console
```

**Done when** the Keycloak admin console is reachable via HTTPS, the `quine-enterprise` realm has the expected users + roles, and a test user can log in via the realm's account UI.

**README addendum** "Step 4: Keycloak with quine-enterprise realm."

---

### Step 5 — Wire QE RBAC against Keycloak

**Goal:** Connect QE's OIDC config to Keycloak; verify role-based access end-to-end.

**What's added**
- QE config: `quine.oidc.*` set to Keycloak's discovery URL, client ID, etc.
- ConfigMap annotated with `service.beta.openshift.io/inject-cabundle: "true"` (OpenShift fills it with the service-ca CA bundle); mounted into the QE pod so the JVM truststore trusts Keycloak's service-ca cert
- Keycloak client redirect URIs updated to include the QE Route URL

**Verification**

```bash
# Browser: hit the QE Route — should redirect to Keycloak login
# Log in as 'admin1'; expect to land in QE with admin role
oc logs -n thatdot-openshift -l app=quine-enterprise | grep -i "oidc\|claim"  # token claims visible
# Log out; log in as 'analyst1'; confirm restricted access (no admin endpoints)
```

**Done when** all four DoD bullets from the Jira ticket are satisfied:
- QE reachable via Route with TLS, configured to use Cassandra as persistor ✓
- OIDC login through Keycloak; logged-in user has expected role ✓
- Ingest query + standing query running, persistence to Cassandra observable ✓
- README walks another engineer through the same path ✓

**README addendum** "Step 5: RBAC enabled" — final state. README is now the v1 deliverable.

---

## TL;DR checklist

Cross off as completed.

### Prerequisites
- [ ] `crc`, `oc`, `helm`, `git`, `gitleaks`, `pre-commit` installed
- [ ] Red Hat developer account; pull secret downloaded
- [ ] OpenShift Local started (`crc start`); `oc whoami` returns `kubeadmin`
- [ ] GitHub repo created (public)
- [ ] `.gitignore` + pre-commit gitleaks hook in place before first push
- [ ] `QE_LICENSE_KEY` available as env var when needed

### Implementation
- [ ] **Step 1** — nginx via GitOps Operator + Route
- [ ] **Step 2** — Quine Enterprise standalone (RocksDB, no RBAC)
- [ ] **Step 3** — Cassandra added; QE persistor switched
- [ ] **Step 4** — Keycloak deployed with `quine-enterprise` realm
- [ ] **Step 5** — QE RBAC wired against Keycloak

### Wrap-up
- [ ] README reads as a complete walk-through for a fresh engineer
- [ ] `IMPLEMENTATION_PLAN.md` reviewed and reflects what was actually done (or call out divergences)
- [ ] Jira QU-2539 closed; sub-issues closed or rolled forward
