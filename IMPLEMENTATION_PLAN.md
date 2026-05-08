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
crc config set memory 18432      # 18 GB recommended (16 GB is the floor — full stack at step 5 is tight under that)
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

### Trust the CRC ingress CA (optional, removes browser warnings)

CRC ships with a self-signed cluster CA. Browsers don't trust it, so the OpenShift web console and every Route you create will show a security warning. The included script extracts the cluster's current ingress CA and adds it to the macOS System keychain (Chrome + Safari).

```bash
./scripts/trust-crc-ca.sh
```

The script is idempotent — re-run it after `crc delete` + `crc start`, since the cluster regenerates its CA on each fresh deploy. Prior `ingress-operator@*` certs are removed before the new one is added. Firefox uses its own trust store — see the script's output for the manual import path.

### Repo safety nets (do this before the first commit)

- `.gitignore` excluding `.env`, `.env.*`, `*.key`, `*.pem`, `*.p12`, `*.jks`, `secrets/`, `*-license-secret.yaml`, `kubeconfig`
- `pre-commit install` with `gitleaks` hook in `.pre-commit-config.yaml`
- README discloses required env vars; never their values

---

## Step-by-step

### Step 1 — OpenShift Project + GitOps Operator + nginx via Route

**Goal:** Prove the full deployment loop (GitHub → OpenShift GitOps → manifest sync → Route → browser) works on a known-good workload before introducing any product complexity.

**What's added**
- `bootstrap/gitops-operator-subscription.yaml`: OperatorGroup + Subscription for OpenShift GitOps. Applied directly with `oc apply` — the seed that bootstraps GitOps itself.
- `bootstrap/application-step-1.yaml`: ArgoCD `Application` CR. Applied directly with `oc apply` to seed the step-1 sync.
- `manifests/step-1/`: GitOps-managed content — `Namespace` (`thatdot-openshift`) + nginx Deployment + Service + Route (edge TLS termination).

**Order of operations**

Manifest-driven throughout — no OperatorHub UI clicks, no `oc new-project`. Every piece of cluster state lives as YAML in this repo so the deployment is reproducible from a fresh clone.

1. *(Prereq)* Public GitHub repo exists and you can `git push` to it.
2. Write `bootstrap/gitops-operator-subscription.yaml` (an `OperatorGroup` for the operator's install namespace + the `Subscription` to the `redhat-operators` catalog channel). Apply it:
   ```bash
   oc apply -f bootstrap/gitops-operator-subscription.yaml
   oc rollout status deploy/openshift-gitops-server -n openshift-gitops --timeout=300s
   ```
3. Write `manifests/step-1/` — `namespace.yaml` (creates `thatdot-openshift`), `nginx-deployment.yaml`, `nginx-service.yaml`, `nginx-route.yaml`.
4. Write `bootstrap/application-step-1.yaml`. Set `spec.source.targetRevision` to **your active branch** (not `main`) during iteration. Set `spec.syncPolicy.syncOptions: [CreateNamespace=true]` as a safety net.
5. Commit and push the changes from steps 2–4 to your branch.
6. Apply the Application CR:
   ```bash
   oc apply -f bootstrap/application-step-1.yaml
   ```
   *Tip:* `./scripts/bootstrap.sh` does steps 2 *and* 6 (Subscription apply + ArgoCD wait + every `bootstrap/application-*.yaml`) in one command. Use it for fresh-clone deploys, re-dos from scratch, or after any cluster reset.
7. Watch the sync: `oc get application -n openshift-gitops -w` (or open the ArgoCD UI). Verify when Synced + Healthy.

The two `bootstrap/` files are *not* themselves GitOps-managed — they're applied directly. Everything else lives under `manifests/step-1/` and is sync-controlled by the Application CR.

**Gotchas to know in advance**

- **Use a non-root nginx image.** Standard `nginx:latest` runs as root and binds port 80; under OpenShift's `restricted-v2` SCC (random UID, no `CAP_NET_BIND_SERVICE`) the pod will crashloop. Use **`nginxinc/nginx-unprivileged:latest`**, which runs as a non-root user and binds port `8080`. The Service `targetPort` should be `8080`, the Route `port.targetPort` should match. Every workload after step 1 hits this same SCC reality — internalize the pattern now.
- **Track your iteration branch, not `main`.** During step 1 you'll be pushing manifest tweaks repeatedly to refine until ArgoCD reports Healthy. Set `Application.spec.source.targetRevision` to your branch (e.g., `step-1`). When the step-1 PR merges, update `targetRevision` to `main` as part of the merge cleanup. Otherwise every iteration requires a PR merge before ArgoCD picks it up.
- **Route TLS:** use `edge` termination (`spec.tls.termination: edge`). The cluster's default wildcard cert handles HTTPS browser-side; plain HTTP between the OpenShift router and the nginx pod. No PEM material lands in the repo.
- **OpenShift GitOps's ArgoCD is namespace-scoped by default.** It can only manage resources in `openshift-gitops` until you explicitly grant it more. The OpenShift-native way to do this is the **`argocd.argoproj.io/managed-by: openshift-gitops` label** on the target namespace — the operator watches for this label and creates the RoleBinding automatically. Every namespace we deploy into (`thatdot-openshift`, etc.) needs this label. Same idiom on CRC as on Wells Fargo's eventual cluster — not a workaround.

**Verification**

```bash
oc get csv -A | grep gitops                                 # GitOps Operator: Succeeded (any namespace)
oc get pods -n openshift-gitops                             # argocd-* pods Running
oc get application -n openshift-gitops                      # Synced + Healthy
oc get pods -n thatdot-openshift                            # nginx Running
oc describe pod -n thatdot-openshift -l app=nginx | grep scc  # restricted-v2
oc get route -n thatdot-openshift                           # HOST/PORT visible
ROUTE=$(oc get route nginx -n thatdot-openshift -o jsonpath='{.spec.host}')
curl -sk "https://$ROUTE" | head -5                         # nginx welcome HTML
open "https://$ROUTE"                                       # browser confirmation (cert is trusted via trust-crc-ca.sh)
```

**Done when** the Route URL serves the nginx welcome page in a browser, and the GitOps Application reports Synced + Healthy.

**README addendum** "Step 1: Hello, OpenShift" — install commands, verification, what you've just proved.

---

### Step 2 — Quine Enterprise alone (no Cassandra, no RBAC)

**Goal:** QE running on OpenShift with no external dependencies. Validates the QE image runs under `restricted-v2` SCC, the private-registry pull-secret pattern works, the Kustomize+Helm rendering pattern works under OpenShift GitOps, and Route + edge TLS work for an actual product UI.

**Naming convention introduced:** files and directories use semantic names, not step numbers. `application-quine-enterprise.yaml`, `manifests/quine-enterprise/`. Step numbers live in branch names and the IMPLEMENTATION_PLAN, never in repo paths.

**Architectural refactor: namespace becomes shared infrastructure.** Step 1 put `namespace.yaml` inside `manifests/step-1/` — that becomes a problem when removing step 1, since pruning step-1 would also delete the namespace. Going forward, namespaces live in `bootstrap/namespace-*.yaml`, applied directly by `bootstrap.sh`, never owned by an Application's prune logic.

**What's added**
- `bootstrap/namespace-thatdot-openshift.yaml` — refactored from `manifests/step-1/namespace.yaml`. Carries the `argocd.argoproj.io/managed-by` label.
- `bootstrap/application-quine-enterprise.yaml` — ArgoCD Application; single-source pointing at `manifests/quine-enterprise/`.
- `manifests/quine-enterprise/`:
  - `kustomization.yaml` — Kustomize root using `helmCharts:` to pull QE chart 0.5.3 from `helm.thatdot.com`, plus `resources: [route.yaml]` for the OpenShift Route.
  - `values.yaml` — QE Helm values: image from private registry (`registry.license-server.dev.thatdot.com/thatdot/quine-enterprise:main`, `pullPolicy: Always`), `cassandra.enabled: false`, `oidc.enabled: false`, `imagePullSecrets: [{name: thatdot-registry-creds}]`, single host, resource limits.
  - `route.yaml` — edge-TLS Route exposing QE on the Service's named port.
- `scripts/create-license-secret.sh` — idempotent; creates `qe-license` Secret from `$QE_LICENSE_KEY`.
- `scripts/create-thatdot-registry-pull-secret.sh` — idempotent; creates `thatdot-registry-creds` from `$THATDOT_REGISTRY_USERNAME` + `$THATDOT_REGISTRY_PASSWORD`.
- Updated `scripts/bootstrap.sh` — patches the ArgoCD instance with `kustomizeBuildOptions: --enable-helm` (required for Kustomize's helmCharts generator), applies any `bootstrap/namespace-*.yaml` before Application CRs.

**Removed**
- `manifests/step-1/` directory
- `bootstrap/application-step-1.yaml`

**Order of operations**

Manifest-driven throughout. Steps interleave git, cluster, and shell actions — read carefully.

1. *(Prereq, on `step-2-basic-qe` branch)* Confirm env vars are loaded:
   ```bash
   echo "$THATDOT_REGISTRY_USERNAME" && echo "${QE_LICENSE_KEY:0:6}..."
   ```
2. *(Already done by Claude)* All new files written under `bootstrap/`, `manifests/quine-enterprise/`, `scripts/`, plus updates to `bootstrap.sh`, `IMPLEMENTATION_PLAN.md`, `CLAUDE.md`.
3. Remove the obsolete step-1 artifacts from git:
   ```bash
   git rm -rf manifests/step-1
   git rm bootstrap/application-step-1.yaml
   ```
4. Commit + push to `step-2-basic-qe`.
5. Cluster cleanup — delete the step-1 Application; the finalizer cascades to nginx Deployment + Service + Route + namespace:
   ```bash
   oc delete application step-1 -n openshift-gitops
   ```
6. Re-create the namespace from the new bootstrap file:
   ```bash
   oc apply -f bootstrap/namespace-thatdot-openshift.yaml
   ```
7. Create the secrets (must happen *after* namespace exists, *before* QE pod tries to pull):
   ```bash
   ./scripts/create-license-secret.sh
   ./scripts/create-thatdot-registry-pull-secret.sh
   ```
8. Run the bootstrap (applies the `--enable-helm` patch, applies `application-quine-enterprise.yaml`):
   ```bash
   ./scripts/bootstrap.sh
   ```
9. Watch the sync until `Synced + Healthy`:
   ```bash
   oc get application quine-enterprise -n openshift-gitops -w
   ```
10. Verify (see Verification below).
11. Finale (same shape as step 1): flip `targetRevision: step-2-basic-qe → main` as the last commit on the PR, merge, then `oc apply -f bootstrap/application-quine-enterprise.yaml` from main, branch auto-deletes.

**Gotchas to know in advance**

- **Moving tag + `pullPolicy`.** `image.tag: main` is a moving tag — the registry repoints `:main` to the latest build. Pair it with `image.pullPolicy: Always` so the kubelet re-pulls on every pod restart. Without `Always`, you'll serve a stale image cached on the node from the first pull.
- **Kustomize+Helm needs `--enable-helm`.** ArgoCD's default Kustomize integration ignores `helmCharts:` blocks unless this flag is passed. `bootstrap.sh` patches the ArgoCD CR to set it. If you ever stand up a separate ArgoCD instance, remember to set the same flag.
- **Persistor is off → data is ephemeral.** `cassandra.enabled: false` means QE runs without any persistor — in-memory only. Pod restart wipes all state. This is correct and expected for step 2; step 3 introduces Cassandra. Any Cypher round-trip is purely "did the engine boot," not a persistence test.
- **Pull secret + license secret are namespace-scoped.** Both must exist in `thatdot-openshift` *before* the QE pod tries to start, otherwise you get `ImagePullBackOff` (no pull secret) or `CreateContainerConfigError` (no license secret). The bootstrap script prints a reminder if either is missing.

**Verification**

```bash
# ArgoCD reports the Application healthy
oc get application quine-enterprise -n openshift-gitops      # Synced + Healthy

# Pod is Running, no SCC violations
oc get pods -n thatdot-openshift -l app.kubernetes.io/name=quine-enterprise
oc describe pod -n thatdot-openshift -l app.kubernetes.io/name=quine-enterprise | grep -E 'scc|runAsUser'

# Pod logs show QE started
oc logs -n thatdot-openshift -l app.kubernetes.io/name=quine-enterprise --tail=50 | grep -iE 'started|listening|license'

# Route serves the QE UI
ROUTE=$(oc get route quine-enterprise -n thatdot-openshift -o jsonpath='{.spec.host}')
curl -sk "https://$ROUTE/api/v2/openapi.json" | head -5     # OpenAPI spec is reachable
open "https://$ROUTE"                                       # browser: QE landing page (no auth required)

# In the browser, run a Cypher query:
#   CREATE (n:Test {name: 'hello'}) RETURN n
# Returns the node. Refresh — still there (in-memory).
# Bounce the pod — data is gone (expected; step 3 fixes this with Cassandra).
oc delete pod -n thatdot-openshift -l app.kubernetes.io/name=quine-enterprise
# Wait for new pod, re-query — node is gone. ✓ correct behavior for step 2.
```

**Done when** the QE UI is reachable via Route, a Cypher round-trip works against in-memory state, and the Application is `Synced + Healthy`. Persistence across pod restart is *not* expected — that's step 3's responsibility.

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
- [x] `crc`, `oc`, `helm`, `git`, `gitleaks`, `pre-commit` installed
- [x] Red Hat developer account; pull secret downloaded
- [x] OpenShift Local started (`crc start`); `oc whoami` returns `kubeadmin`
- [x] GitHub repo created (public)
- [x] `.gitignore` + pre-commit gitleaks hook in place before first push
- [x] `QE_LICENSE_KEY` available as env var when needed

### Implementation
- [x] **Step 1** — nginx via GitOps Operator + Route
- [ ] **Step 2** — Quine Enterprise standalone (RocksDB, no RBAC)
- [ ] **Step 3** — Cassandra added; QE persistor switched
- [ ] **Step 4** — Keycloak deployed with `quine-enterprise` realm
- [ ] **Step 5** — QE RBAC wired against Keycloak

### Wrap-up
- [ ] README reads as a complete walk-through for a fresh engineer
- [ ] `IMPLEMENTATION_PLAN.md` reviewed and reflects what was actually done (or call out divergences)
- [ ] Jira QU-2539 closed; sub-issues closed or rolled forward
