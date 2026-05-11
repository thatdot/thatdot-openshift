# Implementation Plan: Quine Enterprise on OpenShift

Tracking ticket: **[QU-2539](https://thatdot.atlassian.net/browse/QU-2539)** — Deploy Quine Enterprise w/ Cassandra in OpenShift. Discovery + first implementation pass for thatDot's enterprise OpenShift deployment story.

## Strategy

Walking-skeleton approach. Each step adds *exactly one* unknown so failures have a single possible cause. Each step ends with a verifiable success criterion before the next begins. The README accretes alongside the manifests — every step contributes a section.

## Architectural decisions (locked in)

- **Local cluster:** OpenShift Local (formerly CRC) — single-node OCP in a VM. Same OCP bits as a production OpenShift cluster.
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
- **OpenShift GitOps's ArgoCD is namespace-scoped by default.** It can only manage resources in `openshift-gitops` until you explicitly grant it more. The OpenShift-native way to do this is the **`argocd.argoproj.io/managed-by: openshift-gitops` label** on the target namespace — the operator watches for this label and creates the RoleBinding automatically. Every namespace we deploy into (`thatdot-openshift`, etc.) needs this label. Same idiom on CRC as on a production OpenShift cluster — not a workaround.

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

Manifest-driven throughout. nginx and QE coexist briefly during step 2 — the cleanup of step 1 happens at the end, just before the PR merges, to avoid taking the namespace down while QE is still using it.

1. *(Prereq, on `step-2-basic-qe` branch)* Confirm env vars are loaded so `bootstrap.sh` will auto-create the secrets:
   ```bash
   echo "$THATDOT_REGISTRY_USERNAME" && echo "${QE_LICENSE_KEY:0:6}..."
   ```
2. *(Already done by Claude)* All new files written under `bootstrap/`, `manifests/quine-enterprise/`, `scripts/`, plus updates to `bootstrap.sh`, `IMPLEMENTATION_PLAN.md`, `CLAUDE.md`.
3. Commit + push to `step-2-basic-qe`. (Don't delete step-1 files yet — that comes after QE is verified.)
4. Run the bootstrap. It is fully idempotent: applies the `--enable-helm` patch, the new namespace, both secrets (because env vars are set), and `application-quine-enterprise.yaml`. The existing step-1 nginx deployment is unaffected.
   ```bash
   ./scripts/bootstrap.sh
   ```
5. Watch the sync until QE is `Synced + Healthy`:
   ```bash
   oc get application quine-enterprise -n openshift-gitops -w
   ```
6. Verify (see Verification below). nginx is still running at its Route; QE is running at its own Route. No conflict.
7. Cleanup step 1 — *only after QE is verified*. Order matters: strip the instance label first so the namespace survives the Application deletion.
   ```bash
   # Detach the namespace from step-1's ownership so the cascade doesn't take it down
   oc label namespace thatdot-openshift app.kubernetes.io/instance-

   # Delete the step-1 Application; its finalizer cascades to nginx Deployment/Service/Route only
   oc delete application step-1 -n openshift-gitops

   # Remove the obsolete files from git
   git rm -rf manifests/step-1
   git rm bootstrap/application-step-1.yaml
   git commit -m "step 2: remove obsolete nginx artifacts"
   git push origin step-2-basic-qe
   ```
8. Finale (same shape as step 1): flip `targetRevision: step-2-basic-qe → main` as the last commit on the PR, merge, then `oc apply -f bootstrap/application-quine-enterprise.yaml` from main, branch auto-deletes.

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

### Step 3 — Add Cassandra (operator-managed); switch QE persistor

> **Note on layout drift:** Step 5 refactored `cass-operator-subscription.yaml` from `manifests/platform/` (where step 3 put it) into `manifests/cassandra/`, aligning Cassandra with the single-Application-boundary pattern adopted for the Keycloak stack. The narrative below preserves step 3's *original* layout for historical context — the *current* directory tree is documented in CLAUDE.md and in step 5's Layout block.

**Goal:** Verify a stateful workload runs under `restricted-v2` SCC, and QE successfully writes through to Cassandra. The **win condition**: a Cypher write *survives a QE pod restart*, proving the persistor is durable rather than in-memory.

**Architectural choice — k8ssandra cass-operator over Bitnami chart:**

The OpenShift-native path is the [k8ssandra `cass-operator`](https://k8ssandra.io) from OperatorHub's community catalog. It's SCC-aware, models Cassandra as a `CassandraDatacenter` CR (single declarative manifest), and uses the same install idiom as our GitOps Operator (Subscription + OperatorGroup). The Bitnami Helm chart is the alternative path — it works, but requires SCC workarounds (`volumePermissions.enabled: false`), pulls from `bitnamilegacy/*` (maintenance-only), and was designed for vanilla Kubernetes. Pattern asymmetry vs. step 2's QE chart is intentional: step 2 uses Helm because that's how QE ships; step 3 uses an operator because that's how OpenShift expects stateful platform components.

**What's added**

- `bootstrap/cass-operator-subscription.yaml` — OperatorGroup + Subscription (no namespace creation; reuses `thatdot-openshift`). Operator package is **`cass-operator-community`** (the community-operators catalog entry from k8ssandra; the bare `cass-operator` name belongs to a different/conflicting entry). Channel `stable`. Install mode **OwnNamespace**: the OperatorGroup `thatdot-openshift-operators` lives in `thatdot-openshift` and targets that same namespace, so the operator pod runs alongside the workloads it manages. Avoids `AllNamespaces` mode (which would force the operator into cluster-scoped `openshift-operators` and conflict with our namespace-scoped GitOps install). The same OperatorGroup will host future namespace-scoped operators (e.g., Keycloak in step 4) without modification.
- `bootstrap/application-cassandra.yaml` — ArgoCD Application syncing `manifests/cassandra/`. `targetRevision: step-3-cassandra` during iteration.
- `manifests/cassandra/`:
  - `kustomization.yaml` — Kustomize root listing the resources to apply. No Helm chart here — the operator handles rendering.
  - `serviceaccount.yaml` — RoleBinding granting the namespace's `default` ServiceAccount the `anyuid` SCC. Required because cass-operator hardcodes pod `securityContext` to UID/GID 999, which `restricted-v2` (default SCC) rejects. (See gotcha below for why we bind `default` rather than a dedicated SA.)
  - `cassandradatacenter.yaml` — `CassandraDatacenter` CR (`apiVersion: cassandra.datastax.com/v1beta1`) named `dc1`, cluster name `quine`. Single node (`size: 1`), 512MB heap via `spec.config.jvm-server-options.{initial,max}_heap_size`, 2Gi PVC via `spec.storageConfig.cassandraDataVolumeClaimSpec` against `crc-csi-hostpath-provisioner` (the CRC default StorageClass). `spec.serviceAccount` is *intentionally unset* — see gotcha below.
- *(modified)* `manifests/quine-enterprise/values.yaml`:
  - `cassandra.enabled: true`
  - `cassandra.endpoints: quine-dc1-service:9042` — the operator-created CQL service (named `<clusterName>-<dcName>-service`)
  - `cassandra.localDatacenter: dc1` — must match the CR's `metadata.name`
  - `cassandra.plaintextAuth.enabled: false` — matches Cassandra's actual `AllowAllAuthenticator` default (cass-operator creates the `<clusterName>-superuser` Secret defensively, but doesn't enable auth unless you explicitly set `cassandra-yaml.authenticator: PasswordAuthenticator` on the CR). V1 scope: no Cassandra auth.
- *(new)* `manifests/quine-enterprise/patches/wait-for-cassandra.yaml` — Kustomize strategic-merge patch adding an `initContainer` to the QE Deployment that blocks until `quine-dc1-service:9042` accepts a TCP connection. Uses `registry.access.redhat.com/ubi9/ubi-minimal` and the `bash /dev/tcp/...` idiom (no extra tools needed).
- *(modified)* `manifests/quine-enterprise/kustomization.yaml` — adds the `patches:` block referencing the new file.
- *(modified during iteration only — flipped back in finale)* `bootstrap/application-quine-enterprise.yaml`: `targetRevision: main → step-3-cassandra` so QE values changes sync immediately.
- *(modified)* `scripts/bootstrap.sh` — applies the cass-operator subscription before the GitOps applications, and registers a small Lua **custom health check for `CassandraDatacenter`** on the ArgoCD CR (ArgoCD has no built-in health check for that kind, so without this every Cassandra Application would report Healthy as soon as the CR exists, regardless of actual readiness).

**Order of operations**

Step 3 is purely additive — no step-2 cleanup needed.

1. *(Prereq, on `step-3-cassandra` branch)* Confirm env vars are loaded; bootstrap will fail-fast otherwise.
2. *(Already done by Claude when files are written)* New files under `bootstrap/`, `manifests/cassandra/`, plus QE values + QE Application's targetRevision updates.
3. Commit + push to `step-3-cassandra`.
4. Run the bootstrap. Idempotent — installs `cass-operator`, waits for its CRDs to register, applies both Application CRs:
   ```bash
   ./scripts/bootstrap.sh
   ```
5. Watch both syncs. Cassandra takes longer than QE (operator must install, then provision the StatefulSet, then bootstrap the cluster — 3–5 min):
   ```bash
   oc get application -n openshift-gitops -w
   ```
6. Verify (see below). The QE-pod-restart persistence test is the win condition.
7. Finale: flip BOTH `targetRevision`s to `main` as last commit on the PR, merge, post-merge `oc apply` both Applications from main.

**Gotchas to know in advance**

- **Datacenter name discipline.** cass-operator derives the K8s Service from the CR's `metadata.name`. If the CR is named `dc1` and the cluster is `quine`, the Service is `quine-dc1-service`. QE's `cassandra.localDatacenter` must match `dc1` exactly. Mismatch = silent connection failures.
- **`size: 1` is the floor.** `CassandraDatacenter.spec.size` minimum is 1; you cannot scale to 0 as a "stop" mechanism. To shut Cassandra down, delete the CR and re-create.
- **Heap sizing matters on CRC.** Default Cassandra sizes its heap to ~25% of node RAM. Without a cap, it grabs ~4GB and OOM-kills under CRC's tighter ceiling. Pin `initial_heap_size` and `max_heap_size` to `512M` under `spec.config.jvm-server-options` (the `jvm-options` path is for Cassandra 3.x; we're on 4.x).
- **Operator install + Cassandra bootstrap take time.** Cass-operator pull + install: ~1 min. Cassandra cluster bootstrap (Pending → ContainerCreating → Running but Not-Ready → Ready): ~3–5 min on CRC. Don't interpret "still Not-Ready after 90 seconds" as a failure.
- **No built-in ArgoCD health check for `CassandraDatacenter`.** Without a custom check, ArgoCD reports the cassandra Application as Healthy as soon as the CR is *applied* — long before the cluster is actually serving CQL. `bootstrap.sh` patches the ArgoCD CR with a small Lua check that watches `status.cassandraOperatorProgress == "Ready"` and the `Ready` condition. This is what makes "wait for Cassandra to actually be up" a thing ArgoCD can see.
- **QE-after-Cassandra ordering uses an init container, not ArgoCD sync waves.** The init container approach is simpler (no app-of-apps restructuring) and resilient to subsequent restarts (every pod start blocks until Cassandra is reachable). The Kustomize patch lives at `manifests/quine-enterprise/patches/wait-for-cassandra.yaml`.
- **OwnNamespace install for cass-operator** (not AllNamespaces). AllNamespaces would force the operator into `openshift-operators` (cluster-scoped), which conflicts with our namespace-scoped GitOps. OwnNamespace puts the operator in `thatdot-openshift` with an OperatorGroup targeting that same namespace.
- **SCC violation on Cassandra pods is guaranteed, not optional.** cass-operator (v1.23.x) sets `pod.securityContext` to UID/GID/fsGroup 999 — the standard `cassandra` user — and `restricted-v2` (the default OpenShift SCC) requires a random UID in `1000680000–1000689999` and rejects fixed values. Without an `anyuid` grant somewhere, the StatefulSet spams `FailedCreate` events: `pods "..." is forbidden: unable to validate against any security context constraint`.
- **`spec.serviceAccount` on `CassandraDatacenter` is effectively immutable post-creation.** The cass-operator validating webhook (`vcassandradatacenter.kb.io`) rejects updates to that field with `CassandraDatacenter write rejected, attempted to change serviceAccount`. Implication: we can't introduce a dedicated `cassandra-sa` ServiceAccount on an existing CR via GitOps — the apply gets rejected. The pragmatic alternative (and what step 3 ships) is to bind the namespace's `default` ServiceAccount to `anyuid` via a RoleBinding (`manifests/cassandra/serviceaccount.yaml`). cass-operator uses `default` when `spec.serviceAccount` is empty, so the binding takes effect. If you want a dedicated SA in the future, you'd set it in the CR's first apply (before the CR exists on the cluster), or delete-and-recreate the CR. The pod's `runAsNonRoot: true` still prevents actual root, even with anyuid bound.
- **Cass-operator's default is `AllowAllAuthenticator`, not auth-enabled.** Despite the operator auto-creating a `<clusterName>-superuser` Secret on cluster bootstrap, **the cluster does not require auth** until you explicitly set `cassandra-yaml.authenticator: PasswordAuthenticator` on the CR. V1 ships with no auth; QE's `plaintextAuth.enabled: false` matches. If you set QE's `plaintextAuth.enabled: true` against a no-auth Cassandra, you'll see harmless-but-noisy WARN log lines: `did not send an authentication challenge; This is suspicious because the driver expects authentication`. The connection works either way; the mismatch is just log noise.
- **The `--enable-helm` flag is still needed** — QE still uses Kustomize+Helm, and bootstrap.sh's existing patch on the ArgoCD CR continues to apply.

**Verification**

```bash
# Operator installed; CRD available
oc get csv -A | grep -i cass-operator                                # Succeeded
oc get crd cassandradatacenters.cassandra.datastax.com               # exists

# ArgoCD Applications healthy
oc get application -n openshift-gitops                               # quine-enterprise + cassandra both Synced + Healthy

# CassandraDatacenter reconciled by the operator
oc get cassandradatacenter -n thatdot-openshift                      # dc1 — Ready: True
oc get pods -n thatdot-openshift -l cassandra.datastax.com/cluster=quine
oc describe pod -n thatdot-openshift -l cassandra.datastax.com/cluster=quine | grep -E 'scc|fsGroup'
oc exec -n thatdot-openshift quine-dc1-default-sts-0 -c cassandra -- nodetool status   # UN line for the node

# QE picked up the Cassandra config
oc logs -n thatdot-openshift -l app.kubernetes.io/name=quine-enterprise --tail=200 \
    | grep -iE 'cassandra|persistor|connect|established|created keyspace'

# THE WIN CONDITION — persistence survives a pod restart
ROUTE=$(oc get route quine-enterprise -n thatdot-openshift -o jsonpath='{.spec.host}')
open "https://$ROUTE"
# In QE UI:  CREATE (n:Test {tag: 'step-3'}) RETURN n
# Refresh — node visible.
oc delete pod -n thatdot-openshift -l app.kubernetes.io/name=quine-enterprise
# Wait for new pod (oc get pods -w), then re-query in browser:
#   MATCH (n:Test {tag: 'step-3'}) RETURN n
# Node STILL THERE — this is what step 3 proves.

# Sanity: data lives in Cassandra (v1 uses AllowAllAuthenticator — no creds needed)
oc exec -n thatdot-openshift quine-dc1-default-sts-0 -c cassandra -- \
    cqlsh -e "DESCRIBE KEYSPACES"
# 'quine' keyspace appears
```

**Done when** the `MATCH` query after the QE pod restart returns the node *and* the `quine` keyspace is observable in `cqlsh`. Both Applications report `Synced + Healthy` in ArgoCD.

**README addendum** "Step 3: Cassandra-backed persistence (operator-managed)."

---

### Step 4 — App-of-apps refactor (platform/product split)

> **Note on layout drift:** Step 5 moved `cass-operator-subscription.yaml` from `manifests/platform/` (described below) into `manifests/cassandra/` to unify with the Keycloak-stack pattern. Step 4's narrative below reflects the layout *as built at step 4*; CLAUDE.md + step 5 document the current state.

**Goal:** Shrink `bootstrap.sh` to a minimal seed and let GitOps own the rest. Reorganize manifests into a 3-level app-of-apps hierarchy (`root → platform / product → leaf`) so adding a new operator or workload becomes "edit one folder, commit" rather than "edit bash + re-run on every cluster." Foundational refactor *before* Keycloak — easier to do this with one workload + one infra dep than with four.

**Architectural decisions baked in**

- **3 levels exactly.** Root → category (platform/product) → leaf (per workload). The Codefresh "max 3" guidance counts the manifest layer too, but for nested Applications this is the standard 2-deep structure. Don't go deeper; if more grouping is ever needed, switch the wrapper layer to ApplicationSet rather than nesting further.
- **Platform vs. product split.**
  - *Platform* = operator subscriptions + the infra workloads QE depends on (Cassandra today; Keycloak in step 5 — identity is platform infra).
  - *Product* = differentiating workloads (QE today; Novelty if scope grows).
- **Operator subscriptions become GitOps-managed.** `cass-operator-subscription.yaml` moves out of imperative `bootstrap/` into `manifests/platform/`. Chicken-and-egg things stay in `bootstrap/`: the GitOps Operator install, ArgoCD instance customizations, the shared `thatdot-openshift` namespace (preconditional — the OpenShift GitOps Operator needs the `argocd.argoproj.io/managed-by` label present *before* ArgoCD tries to sync into the namespace, otherwise the first wrapper sync races with the operator's RoleBinding provisioning; secrets also need the namespace to exist), and the root Application seed.
- **Rely on built-in Application health.** Modern ArgoCD has a working built-in health check for the `argoproj.io/Application` kind: a wrapper Application reports Healthy when its children are Healthy. We start without any custom Application-level Lua. If observation shows wrappers reporting Healthy prematurely (or sync-wave gating not actually waiting for children), we add the Lua then — not before.
- **Sync-waves and init containers are complementary, not alternatives.** Sync-waves at the Application level (newly added in this step's tree) handle "things created in the right order" — wave 0 wrappers / Subscriptions before wave 1 wrappers / their CRs. The existing `wait-for-cassandra` init container in `manifests/quine-enterprise/patches/` (from step 3) handles "the dep is actually serving" — and continues to fire on every pod restart. Both are required for any cross-service dependency. See the Conventions section in README and the Critical Rules bullet in CLAUDE.md.

**What's added**
- `bootstrap/root-application.yaml` — single seed Application; `spec.source.path: manifests/root`; carries `resources-finalizer.argocd.argoproj.io` so deletion cascades through the whole tree.
- `manifests/root/`:
  - `kustomization.yaml` — `resources: [application-platform.yaml, application-product.yaml]`.
  - `application-platform.yaml` — sync-wave `"0"`, points at `manifests/platform/`, carries `resources-finalizer`.
  - `application-product.yaml` — sync-wave `"1"`, points at `manifests/product/`, carries `resources-finalizer`.
- `manifests/platform/`:
  - `kustomization.yaml`
  - `cass-operator-subscription.yaml` *(moved from `bootstrap/`, sync-wave `"0"`)*
  - `application-cassandra.yaml` *(moved from `bootstrap/`, sync-wave `"1"`)*
- `manifests/product/`:
  - `kustomization.yaml`
  - `application-quine-enterprise.yaml` *(moved from `bootstrap/`)*

`bootstrap/argocd-customizations.yaml` is unchanged from step 3 (still just `--enable-helm` + the `CassandraDatacenter` Lua check). No new Lua in step 4 — see Architectural decisions for the rationale.

**What's removed**
- `bootstrap/application-quine-enterprise.yaml`, `bootstrap/application-cassandra.yaml`, `bootstrap/cass-operator-subscription.yaml` — moved into `manifests/`.
- The three loops in `scripts/bootstrap.sh` (over `namespace-*.yaml`, `*-operator-subscription.yaml`, `application-*.yaml`) — replaced by a direct `oc apply` of the namespace and a single `oc apply -f bootstrap/root-application.yaml` for the seed.

**Refactored**
- `scripts/bootstrap.sh` collapses to: preflight → install GitOps Operator → wait → patch ArgoCD customizations → apply namespace → create out-of-band secrets → seed root Application. Roughly half its current length.
- `CLAUDE.md` "File layout" + "Useful gotchas" sections updated for the new tree.
- `README.md` "What's here" reflects the new directory layout.

**Order of operations**

1. **Clean slate.** No partial migration — wipe and rebuild for a verified-clean starting state. Manifests + secrets are all reproducible from Git + env vars; nothing in the cluster is precious. The new bootstrap path is what's being tested, so exercising it from absolute zero is the strongest verification.
   ```bash
   crc delete -f
   crc start --pull-secret-file ~/Downloads/pull-secret.txt
   eval "$(crc oc-env)"
   oc login -u kubeadmin -p <pw> https://api.crc.testing:6443      # `crc console --credentials` for pw
   ./scripts/trust-crc-ca.sh                                        # CRC regenerates its CA on each fresh deploy
   ```
   Verify clean before proceeding:
   ```bash
   crc status                                       # Running, fresh
   oc get ns | grep -E 'thatdot|gitops|operators'   # only kube-* / openshift-* defaults; no openshift-gitops
   oc get crd | grep -E 'cassandra|argo'            # empty
   ```

2. *(On `app-of-apps` branch, already done by Claude when files are written)* New manifest tree, new root Application, updated `argocd-customizations.yaml`, slimmed `bootstrap.sh`, updated docs.

3. Commit + push to `app-of-apps`. Set `targetRevision: app-of-apps` on every Application CR (root + both wrappers + both leaves) for the iteration phase.

4. Run the bootstrap. New flow: install GitOps Operator → wait → patch ArgoCD customizations → apply namespace → create secrets → seed *one* Application:
   ```bash
   ./scripts/bootstrap.sh
   ```

5. Watch the cascade. Root → platform (subs + Cassandra) → product (QE). Full cold-start from empty cluster ~5–7 min:
   ```bash
   oc get application -n openshift-gitops -w
   ```

6. Verify (see below). The win condition is identical to step 3 — Cypher write survives QE pod restart — but reached via the new bootstrap path.

7. Finale: flip every `targetRevision` to `main` as last commit on the PR, merge, post-merge `oc apply -f bootstrap/root-application.yaml` from main.

**Gotchas to know in advance**

- **Sync-wave gating depends on built-in health checks doing the right thing.** ArgoCD's built-in `argoproj.io/Application` health check should keep `application-platform` Progressing until its children are Healthy, and the built-in `Subscription` check should keep `cass-operator-subscription` Progressing until the CSV is Succeeded. If observation shows premature Healthy on a wrapper, the fallback is a custom Lua check on `Application` (and possibly `Subscription`) added to `argocd-customizations.yaml`. Don't write the Lua speculatively — only when a real failure mode appears.
- **Expect transient `OutOfSync/Failed` on first sync.** When `application-product` first reaches QE, Cassandra's CRD must already exist (planted by `application-platform`). Even with the health check, OLM reconciliation can lag; ArgoCD retries automatically. If retry backoff stretches the wait, force a re-fetch: `oc annotate application <app> argocd.argoproj.io/refresh=hard --overwrite`.
- **`prune: true` everywhere means deletion cascades.** Removing `application-X.yaml` from a wrapper's folder deletes that child *and its workload* (via the resources-finalizer). Intentional — that's the GitOps semantics — but worth knowing for "I deleted a file to test something."
- **Three is the cap.** Don't split product into e.g. "stateful" / "stateless" later. 4+ levels turns debugging into a multi-step traversal and the Codefresh research is explicit about avoiding it. ApplicationSet at the wrapper layer is the escape hatch if you outgrow the structure.
- **`bootstrap/` semantics are narrowed.** Now means *only* "applied imperatively because GitOps can't (yet) manage it." Four files only: GitOps Operator subscription, ArgoCD customizations, the shared namespace (preconditional — see Architectural decisions), and the root Application seed. CLAUDE.md's file-layout section is updated to reflect this rule.
- **Subscription-CSV gap.** ArgoCD says a `Subscription` is Synced once the CR exists, not once the CSV reaches `Succeeded`. ArgoCD's built-in `Subscription` health check should keep it Progressing until the CSV settles, which keeps the wrapper Application Progressing too. On clusters with slow OLM reconciliation this can take 1–2 min — not a failure, just patience.

**Verification**

```bash
# (Clean slate verification covered in Order of Operations step 1)

# Single seed worked — five Applications visible
oc get application -n openshift-gitops
# Expect: root, application-platform, application-product, application-cassandra, application-quine-enterprise
# All Synced + Healthy

# Walk the nesting (no plugin needed)
oc get application -n openshift-gitops \
   -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status
# (or, if the `argocd` CLI is installed + logged in: `argocd app get root --show-managed-resources`)

# Operator + workloads landed in the right namespaces (unchanged from step 3)
oc get csv -n thatdot-openshift                   # cass-operator-community.* — Succeeded
oc get cassandradatacenter -n thatdot-openshift   # dc1 — Ready: True
oc get pods -n thatdot-openshift                  # cass-operator + cassandra + QE all Running

# `bootstrap/` is now minimal
ls bootstrap/
# argocd-customizations.yaml
# gitops-operator-subscription.yaml
# namespace-thatdot-openshift.yaml
# root-application.yaml
# (nothing else)

# WIN CONDITION (same as step 3) — persistence survives QE pod restart
ROUTE=$(oc get route quine-enterprise -n thatdot-openshift -o jsonpath='{.spec.host}')
open "https://$ROUTE"
# In QE UI:  CREATE (n:Test {tag: 'step-4'}) RETURN n
oc delete pod -n thatdot-openshift -l app.kubernetes.io/name=quine-enterprise
# Re-query in browser:  MATCH (n:Test {tag: 'step-4'}) RETURN n   — still there
```

**Done when** every Application reports `Synced + Healthy`, `bootstrap/` contains only the four chicken-and-egg files, and the persistence-after-restart test passes — proving the new bootstrap path produces a functionally identical cluster to the end of step 3.

**README addendum** "Step 4: App-of-apps refactor" — explains the 3-level structure, the platform/product split, and the new minimal `bootstrap.sh`. Updates "What's here" to reflect the new directory layout.

---

### Step 5 — Add Keycloak with `quine-enterprise` realm

**Goal:** Stand up Keycloak (Red Hat Build of Keycloak, "RHBK") with the realm pre-configured, *before* wiring QE to it. Isolates Keycloak issues from OIDC-integration issues. First exercise of the post-step-4 "add a new platform component" workflow — drop a new Application into `manifests/platform/`, watch ArgoCD pick it up.

**Architectural placement:** Keycloak is platform infra (identity, parallel to Cassandra-as-persistence). Lives in the platform layer of the app-of-apps tree, *not* product. Keycloak is consumed by QE the same way Cassandra is — both are dependencies, not differentiating workloads.

**Architectural decisions baked in**

- **RHBK Operator over upstream Keycloak or Helm.** OpenShift-native lane: Subscription from OperatorHub (`redhat-operators` catalog, package `rhbk-operator`), CRDs `Keycloak` + `KeycloakRealmImport` on `k8s.keycloak.org/v2alpha1` (RHBK 26.4 still ships v2alpha1; upstream Keycloak Operator has moved to v2beta1 but Red Hat's build lags — verify with `oc get crd keycloaks.k8s.keycloak.org -o jsonpath='{.spec.versions[*].name}'`). Same install idiom as cass-operator (Subscription + OperatorGroup, OwnNamespace, sync-wave `"0"`). Reuses the existing `thatdot-openshift-operators` OperatorGroup (set up in step 3 and explicitly intended to host future namespace-scoped operators).
- **Bare Postgres Deployment for the Keycloak backing store (pivoted during implementation).** Original plan was CloudNativePG via OperatorHub. The `cloud-native-postgresql` package in `certified-operators` turned out to be EDB's **commercial** "EDB Postgres for Kubernetes" product — its operator pod pulls from `docker.enterprisedb.com/...` with auth required (`invalid username/password: unauthorized`) and expects a pull-secret named `postgresql-operator-pull-secret` we don't have. The curated OpenShift OperatorHub catalogs ship no upstream-CNPG package; the only free alternatives are `crunchy-postgres-operator` (different CR schema with mandatory backups config) or rolling our own. We pivoted to bare Postgres: `Deployment + PVC + Service` using `registry.redhat.io/rhel9/postgresql-16` (Red Hat's OpenShift-aware image, handles `restricted-v2` SCC and reads `POSTGRESQL_*` env vars). Credentials live in a `keycloak-postgres-app` Secret created out-of-band by `scripts/create-keycloak-postgres-secret.sh` (random password, idempotent — preserves the existing password across re-runs). One non-operator workload in `manifests/keycloak/`; everything else still operator-managed.
- **Edge-terminated Route, single Route URL as Keycloak hostname.** `Keycloak.spec.hostname.hostname` = the public Route URL (with `https://`). Browser → router (cluster wildcard cert) → plain HTTP to Keycloak pod. `proxy.headers: xforwarded` so Keycloak generates HTTPS URLs in discovery doc despite seeing HTTP internally. This *will* expose the classic Keycloak TLS-at-ingress gotcha — we configure through it on purpose so the mental model is built before step 6 needs it.
- **Operator-generated client secrets + temporary-password test users.** Public-repo rule: no static credentials in git. Client `secret:` fields left unspecified in the realm import → Keycloak auto-generates; retrieval is `oc exec` + `kcadm.sh` (or admin REST API). Test-user passwords are placeholders with `temporary: true` — Keycloak forces a password reset on first login, so the committed placeholder is useless after first use.
- **Two flavors of identities in the realm: 6 browser/interactive users + 6 service-account CLI clients.** Both shapes are needed for QE. Interactive users (`admin1`...`billing1`) drive the browser OIDC flow tested in step 6. Service-account clients (`qe-cli-superadmin`...`qe-cli-billing`) exist for CLI/machine-to-machine flows — each is a confidential OIDC client with `serviceAccountsEnabled: true`, `standardFlowEnabled: false`, `directAccessGrantsEnabled: false`, and the matching client role pre-mapped onto its built-in service-account user. A consumer (a CLI, a script, a CI job) does the `client_credentials` grant against `qe-cli-<role>` and gets a bearer JWT with the corresponding role claim. Same `secret:`-omitted pattern as the interactive client: all 7 client secrets are operator-generated, retrieved out-of-band.
- **No QE redirect URI in step 5's realm.** That's step 6's job. Step 5's realm boots cold without knowing QE exists; step 6 adds QE's Route URL to the client's `redirectUris`.
- **Single-Application boundary for every platform stack — including a step-3 cleanup pass on Cassandra.** Each platform-layer stack (operators + workload CRs) is owned by *one* Application, ordered by internal sync-waves. The whole Keycloak stack — both operators, Postgres, Keycloak, realm — lives under `application-keycloak`. Same shape now applies to Cassandra: `cass-operator-subscription.yaml` moves from `manifests/platform/` into `manifests/cassandra/`. Motivated by (a) `KeycloakRealmImport`'s fire-once semantics making `oc delete application keycloak` the natural debug loop, and (b) pattern consistency — having one platform stack break the rule for "historical reasons" is the kind of asymmetry that compounds over time. Step 3's original layout was right *at the time*; step 5 promotes the pattern to platform-wide and aligns Cassandra in one motion. See "Layout" and "Reset granularities" below.

**Layout**

```
manifests/platform/                # The wrapper Application (application-platform)
├── kustomization.yaml             # only Application CRs, no operator subs
├── application-cassandra.yaml        (wave 1)
└── application-keycloak.yaml         (wave 1 — NEW)

manifests/cassandra/               # LEAF synced by application-cassandra
├── kustomization.yaml
├── cass-operator-subscription.yaml   (wave 0 — MOVED from manifests/platform/)
├── serviceaccount.yaml               (wave 0 — anyuid RoleBinding)
└── cassandradatacenter.yaml          (wave 1)

manifests/keycloak/                # LEAF synced by application-keycloak (NEW)
├── kustomization.yaml
├── rhbk-operator-subscription.yaml   (wave 0)
├── postgres.yaml                     (wave 1 — bare PVC + Deployment + Service)
├── keycloak.yaml                     (wave 2)
├── route.yaml                        (wave 2)
└── keycloak-realm-import.yaml        (wave 3)
```

Sync-waves *inside* a leaf are scoped to that leaf's Application — `0/1/2/3` are independent of the outer `application-platform → application-cassandra/keycloak` ordering. Both leaves follow the same shape: wave 0 installs the operator(s), wave 1+ applies the CRs the operators reconcile.

**What's added (and refactored)**

Cassandra refactor (moves only — content unchanged):
- `manifests/cassandra/cass-operator-subscription.yaml` — MOVED from `manifests/platform/`. Gains `argocd.argoproj.io/sync-wave: "0"` annotation.
- `manifests/cassandra/serviceaccount.yaml` — gains `sync-wave: "0"` annotation.
- `manifests/cassandra/cassandradatacenter.yaml` — gains `sync-wave: "1"` annotation.
- `manifests/cassandra/kustomization.yaml` — `resources:` adds `cass-operator-subscription.yaml`.
- `manifests/platform/kustomization.yaml` — `resources:` drops `cass-operator-subscription.yaml`.

Keycloak addition (the actual new work):
- `manifests/platform/application-keycloak.yaml` — ArgoCD Application syncing `manifests/keycloak/`. Sibling of `application-cassandra` under the platform wrapper. `resources-finalizer` for cascade-delete consistency.
- `manifests/platform/kustomization.yaml` — `resources:` updated to add `application-keycloak.yaml`. (After the Cassandra refactor + Keycloak add, `manifests/platform/` contains only Application CRs — no operator subs at the wrapper layer.)
- `scripts/create-keycloak-postgres-secret.sh` — idempotent; creates `keycloak-postgres-app` Secret with `username: keycloak` and a 32-char random password if it doesn't already exist. Same shape as the other create-*-secret.sh scripts.
- `scripts/bootstrap.sh` — calls the new secret-creation script alongside the existing license + registry-pull-secret scripts.
- `bootstrap/argocd-customizations.yaml` — adds Lua `resourceHealthChecks` for `k8s.keycloak.org/Keycloak` (Healthy when `conditions[Ready].status == "True"` and `HasErrors` False) and `k8s.keycloak.org/KeycloakRealmImport` (Healthy when `conditions[Done].status == "True"`). Without these, the `keycloak` Application reports Healthy as soon as the CRs are *applied*, regardless of whether the operator has reconciled them — same fundamental problem as the existing CassandraDatacenter check.
- `manifests/keycloak/` (leaf, new):
  - `kustomization.yaml` — `resources:` lists every file below.
  - `rhbk-operator-subscription.yaml` — Subscription to `rhbk-operator` (no new OperatorGroup; reuses `thatdot-openshift-operators` from step 3). `argocd.argoproj.io/sync-wave: "0"`.
  - `postgres.yaml` — bare Postgres backing store: PVC (2Gi, default StorageClass) + Deployment (single replica, `registry.redhat.io/rhel9/postgresql-16` image, env vars from `keycloak-postgres-app` Secret) + ClusterIP Service (`keycloak-postgres:5432`). `sync-wave: "1"`. Replaces the originally-planned CNPG Cluster CR — see Architectural Decisions for the EDB-commercial-package pivot.
  - `keycloak.yaml` — RHBK `Keycloak` CR. Key fields: `instances: 1`, `db.{vendor: postgres, host: keycloak-postgres, port: 5432, database: keycloak, usernameSecret + passwordSecret pointing at keycloak-postgres-app}`, `hostname.hostname: https://<route-url>`, `proxy.headers: xforwarded`, `http.enabled: true`, `ingress.enabled: false` (we own the Route). `sync-wave: "2"`.
  - `route.yaml` — edge-terminated Route exposing the Keycloak Service on port 8080. `host:` left unset so OpenShift assigns `keycloak-thatdot-openshift.apps-crc.testing`. The Route URL has to be computed *before* `keycloak.yaml`'s `hostname.hostname` is set — see Order of Operations. `sync-wave: "2"`.
  - `keycloak-realm-import.yaml` — `KeycloakRealmImport` CR. `sync-wave: "3"`. Realm `quine-enterprise`, ported from `../opstools/keycloak/k8s/realm.json`. Contents:
    - **1 interactive OIDC client `quine-enterprise-client`** (matches opstools naming) — `protocolMappers` for `roles` (client-role mapper) + `audience` (audience mapper), `standardFlowEnabled: true`, `directAccessGrantsEnabled: true`, `secret:` omitted.
    - **6 client roles** on `quine-enterprise-client`: `superadmin`, `admin`, `architect`, `dataengineer`, `analyst`, `billing`.
    - **6 interactive users** `admin1`...`billing1` — placeholder passwords with `temporary: true`, each pre-assigned the matching client role.
    - **6 service-account CLI clients** `qe-cli-superadmin`...`qe-cli-billing` — `serviceAccountsEnabled: true`, `standardFlowEnabled: false`, `directAccessGrantsEnabled: false`, `publicClient: false`, `secret:` omitted. Each carries a `serviceAccountClientRoles` block mapping the corresponding `quine-enterprise-client` client role onto its built-in service-account user, so a `client_credentials` grant produces a JWT with the right role claim.
    - **No QE redirect URIs yet** on `quine-enterprise-client` — step 6.

**Iteration ritual:** Flip `targetRevision` only on the chain from `root` down to each modified leaf. Step 5 modifies *two* leaves — `manifests/cassandra/` (Subscription moved in, sync-wave annotations added) and `manifests/keycloak/` (new). Both chains converge at root, so the on-branch set is `root` → `application-platform` → `application-cassandra` + `application-keycloak` — 4 spots. The two unchanged Applications — `application-product`, `application-quine-enterprise` — stay on `main` throughout. Same 4 spots flip back to `main` on PR finale.

**Order of operations**

Clean-slate path — same shape as step 4. Step 5 introduces the platform-wide single-Application-boundary pattern, refactors Cassandra to match, and adds Keycloak. Verifying the whole cascade from absolute zero is the strongest test that the new pattern holds end-to-end. CRC is already deleted; proceed from `crc start`.

1. **Cluster boot.**
   ```bash
   crc start --pull-secret-file ~/Downloads/pull-secret.txt
   eval "$(crc oc-env)"
   oc login -u kubeadmin -p <pw> https://api.crc.testing:6443      # `crc console --credentials` for pw
   ./scripts/trust-crc-ca.sh                                        # CRC regenerates its CA on each fresh deploy
   ```
   Verify clean before proceeding:
   ```bash
   oc get ns | grep -E 'thatdot|gitops|operators'   # only kube-* / openshift-* defaults; no openshift-gitops
   oc get crd | grep -E 'cassandra|keycloak|postgresql|argo'  # empty
   ```

2. **(Prereq, on `step-5-keycloak` branch)** Env vars unchanged from step 4 — same `QE_LICENSE_KEY`, `THATDOT_REGISTRY_USERNAME`, `THATDOT_REGISTRY_PASSWORD`. The Keycloak admin password is operator-generated and stored in `keycloak-initial-admin` — looked up post-deploy, never pre-set.

3. **Compute the Route URL ahead of time** so `Keycloak.spec.hostname.hostname` can be written into the manifest before first apply. On CRC, the apps domain is deterministic: `apps-crc.testing`. Route hostname follows the OpenShift pattern `<route-name>-<namespace>.apps-crc.testing` → `keycloak-thatdot-openshift.apps-crc.testing`. Hardcode this into `keycloak.yaml`'s `hostname.hostname: https://keycloak-thatdot-openshift.apps-crc.testing`.

4. *(Already done by Claude when files are written)* Cassandra refactor + Keycloak addition: files moved/added under `manifests/cassandra/` and `manifests/keycloak/`, `manifests/platform/kustomization.yaml` updated, branch-flips on root + application-platform + application-cassandra + application-keycloak (4 spots).

5. Commit + push to `step-5-keycloak`.

6. Run the bootstrap. New flow is unchanged from step 4 — install GitOps Operator → wait → patch ArgoCD customizations → apply namespace → create secrets → seed root Application:
   ```bash
   ./scripts/bootstrap.sh
   ```

7. Watch the full cascade. Cold-start with one new operator (RHBK) plus Cassandra refactor plus bare Postgres: ~7-10 min:
   ```bash
   oc get application -n openshift-gitops -w
   ```
   Order you'll observe: GitOps Operator ready → bootstrap.sh creates Secrets (license, registry pull, Keycloak DB password) → root Application syncs → platform + product wrappers reconcile → operator subscriptions install (cass-operator + rhbk, wave 0 inside their leaves) → CRDs land → `CassandraDatacenter` + Postgres `Deployment` reconcile (wave 1) → Keycloak CR + Routes (wave 2) → `KeycloakRealmImport` Job runs (wave 3) → QE waits on Cassandra via init container, then comes up.

8. Verify (see below). Both the persistence-survives-pod-restart (Keycloak) and the existing Cassandra persistence-survives-QE-restart (carryover from step 3, validates the refactor preserves behavior).

9. Finale: flip `targetRevision: step-5-keycloak → main` on the 4-spot chain, merge, post-merge `oc apply -f bootstrap/root-application.yaml` from main.

**Gotchas to know in advance**

- **The TLS-at-ingress gotcha is the headline lesson.** Keycloak embeds its hostname into the OIDC discovery doc, JWT `iss` claim, login redirects, and asset URLs. It has to be told *what URL the browser sees*, not what URL the pod sees. With edge-terminated Route: pod receives plain HTTP; `Keycloak.spec.hostname.hostname` set to `https://...` tells Keycloak what to put in tokens; `proxy.headers: xforwarded` tells Keycloak to trust `X-Forwarded-Proto: https` from the OpenShift router. Misconfigure any of these and the discovery doc serves `http://...` URLs — QE's OIDC validation will refuse to load in step 6. Verify by `curl`ing the discovery endpoint and confirming `issuer` starts with `https://`.
- **Sync-wave gating is *intra*-Application, not inter-Application.** The whole Keycloak stack is in one Application with four waves (0: rhbk-operator-subscription, 1: postgres, 2: keycloak+route, 3: realm). ArgoCD applies wave N+1 after wave N is reported `Synced` — but `Synced` ≠ `Healthy`. With the bare-Postgres pivot, wave 1 is a pure-builtin Deployment+Service+PVC with no CRD chicken-and-egg risk; only wave 2 (`Keycloak`) and wave 3 (`KeycloakRealmImport`) depend on CRDs the wave-0 Subscription installs, and both carry `SkipDryRunOnMissingResource=true` (see Pre-flight gotcha below).
- **Pre-flight dry-run on CRD-dependent resources aborts the whole sync (encountered during step 5 implementation).** Sync-waves order the *apply*, but ArgoCD runs a pre-flight validation on *all* resources in the Application before applying any of them. If a wave-1 resource references a CRD installed by a wave-0 Subscription, the dry-run fails ("no matches for kind …"), the sync is rejected, and wave 0 never runs. After 5 retries ArgoCD gives up; sync error reads "one or more synchronization tasks are not valid (retried 5 times)." **Fix:** add `argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true` annotation to every CRD-dependent resource (in our tree: `CassandraDatacenter`, `Keycloak`, `KeycloakRealmImport`). Sync-waves still gate the apply order correctly; this annotation only disables the pre-flight dry-run that aborts prematurely.
- **`oc delete application` cleans up the Subscription but NOT the CSV.** OLM design: deleting a Subscription removes the desired-state CR but leaves the installed operator (CSV + pods + CRDs) untouched. So `oc delete application keycloak` is *faster than it looks* — operator pods keep running, CRDs stay registered, ArgoCD re-applies the Subscription on recreate and OLM treats it as a no-op against the existing CSV. Estimated reset: ~3-4 min (vs ~5-7 min for true cold install). For a truly nuclear reset including operator uninstall: manually `oc delete csv -l operators.coreos.com/rhbk-operator.thatdot-openshift -n thatdot-openshift` first.
- **Custom Lua health checks for `Keycloak` and `KeycloakRealmImport` are required (added during implementation).** Initial assumption was the built-in Application health fallback would be "good enough." It wasn't — the `keycloak` Application reported Healthy as soon as the CRs were applied, even though the operator hadn't created the Keycloak pod yet. Added `resourceHealthChecks` entries in `bootstrap/argocd-customizations.yaml` for both kinds, mirroring the existing `CassandraDatacenter` check. Healthy now requires `Keycloak.status.conditions[Ready].status == "True"` (and `HasErrors == False`), and `KeycloakRealmImport.status.conditions[Done].status == "True"`.
- **Init-container probe for Postgres readiness?** Bare Postgres's readinessProbe + the Keycloak operator's reconciler should make Keycloak's pod wait for Postgres implicitly: the Service won't route until the Postgres pod is Ready, and the Java process will retry the JDBC connection. If we see CrashLoopBackOff during initial sync from "DB not ready," we add `manifests/keycloak/patches/wait-for-postgres.yaml` with the same `bash /dev/tcp/...` idiom as `wait-for-cassandra.yaml`. Determine empirically.
- **OperatorHub "cloud-native-postgresql" is EDB's commercial product, not upstream CNPG.** Encountered during implementation: the package in `certified-operators` is EDB's "EDB Postgres for Kubernetes," which pulls from a registry that requires a paid subscription. Upstream CloudNativePG isn't shipped in the curated catalogs. This is why step 5 pivots to bare Postgres rather than CNPG. If a future step wants an operator-managed Postgres, `crunchy-postgres-operator` (in `certified-operators`) is the free alternative; its CR schema is different from CNPG's (mandatory pgBackRest config), so a Crunchy pivot is non-trivial.
- **Seven operator-generated client secrets to retrieve.** The realm has 1 interactive client (`quine-enterprise-client`) + 6 CLI service-account clients (`qe-cli-*`). RHBK Operator does NOT automatically stash these in K8s Secrets (unlike `keycloak-initial-admin`). They have to be pulled via `kcadm.sh get clients/<id>/client-secret -r quine-enterprise` against the Keycloak pod. Step 5 verifies the *interactive* client secret can be retrieved and that a `qe-cli-admin` `client_credentials` grant returns a JWT with the right role claim — that's the smoke test that says the realm + service-account-role-mappings are wired correctly. Wiring the secrets into QE config is step 6.
- **Service-account-role-mappings are easy to get wrong in YAML.** In `KeycloakRealmImport`, attaching a client role to a service-account user requires *two* things: (a) `serviceAccountsEnabled: true` on the client, and (b) a `serviceAccountClientRoles:` block at the realm level that maps `<cli-client-name>` → `quine-enterprise-client` → `[<role>]`. Miss part (b) and the client_credentials grant succeeds but the JWT contains no `roles` claim — QE sees a tokenless principal. The verification's JWT-decode step catches this.
- **Test users use placeholder passwords with `temporary: true`.** Committing `placeholder123` is fine because Keycloak forces a password change on first login — the committed value is useless after first use. README documents this.
- **`KeycloakRealmImport` is fire-once-then-stale.** The realm import CR triggers a one-shot Job (`kc.sh import --override`); operator marks `status.conditions[Done]: True` after the Job succeeds and *ignores subsequent edits* to the `realm:` block. This is identical between RHBK and upstream Keycloak Operator. The single-Application layout (operators + Postgres + Keycloak + realm all under `application-keycloak`) is the natural workflow: `oc delete application keycloak` re-creates the CR from cold, which re-triggers the import. See "Reset granularities" below for finer-grained options.
- **Operator-generated admin password (and username).** Keycloak Operator creates Secret `keycloak-initial-admin` in the same namespace with keys `username` and `password` (both random/Red-Hat-defaulted). **RHBK 26.4 sets the username to `temp-admin`, not `admin`** — verified at step-5 implementation time, but don't hardcode it; always read both keys from the Secret. Retrieve once, log in, optionally change. Documented in verification.
- **Realm storage requires DB persistence.** This is what makes the "Keycloak survives pod restart" win condition meaningful — see Verification.

**Reset granularities for iteration**

The single-Application layout gives three levels of reset, from cheapest to most thorough. Use the smallest one that fits the change being debugged.

| Scope | Command | Time | When to use |
|---|---|---|---|
| Realm only (fastest re-import) | `oc delete keycloakrealmimport quine-enterprise -n thatdot-openshift` | ~30s | Iterating realm YAML (clients, roles, users, role-mappings). ArgoCD re-creates the CR from drift; fresh Job re-imports. Postgres data persists, so existing realm contents get overwritten by `OVERWRITE_EXISTING`. |
| Keycloak stack, no operators | `oc delete keycloak keycloak,keycloakrealmimport quine-enterprise,cluster.postgresql.cnpg.io keycloak-postgres -n thatdot-openshift` | ~3 min | Iterating `keycloak.yaml` config (hostname, proxy headers, db settings). Wipes the Postgres DB and Keycloak state; realm re-imports cold. Operator CSVs stay. |
| **Entire Keycloak Application boundary** | `oc delete application keycloak -n openshift-gitops` | ~3-4 min | Anything more involved, or when you want guaranteed clean state. ArgoCD detects drift on `application-platform`, re-creates `application-keycloak`, which re-cascades the whole stack (subs → postgres → keycloak → realm). Operator CSVs/CRDs stay registered, so it's faster than a true cold install. |
| Nuclear (incl. operator uninstall) | Manual `oc delete csv -l operators.coreos.com/rhbk-operator.thatdot-openshift -n thatdot-openshift` + the Application delete above | ~6-7 min | Should rarely be needed; only if an operator itself is wedged. |

**Verification**

```bash
# Operator installed; all relevant CRDs available
oc get csv -n thatdot-openshift | grep -iE 'rhbk|keycloak'                    # rhbk-operator Succeeded
oc get crd keycloaks.k8s.keycloak.org keycloakrealmimports.k8s.keycloak.org   # exist

# ArgoCD Applications healthy
oc get application -n openshift-gitops                                         # all six Synced + Healthy
# Expect: root, application-platform, application-product,
#         cassandra, quine-enterprise, keycloak

# Postgres up (bare Deployment, not CNPG)
oc get pods -n thatdot-openshift -l app=keycloak-postgres                      # Running, 1/1
oc get pvc -n thatdot-openshift keycloak-postgres-data                         # Bound
oc get svc -n thatdot-openshift keycloak-postgres                              # ClusterIP, port 5432

# Keycloak up
oc get keycloak -n thatdot-openshift                                           # keycloak — Ready: True
oc get pods -n thatdot-openshift -l app=keycloak                               # Running, Ready 1/1

# Realm imported
oc get keycloakrealmimport -n thatdot-openshift                                # quine-enterprise — Done: True
oc logs -n thatdot-openshift job/keycloak-quine-enterprise-realm | grep -i 'imported\|done'

# Discovery endpoint serves correct issuer URL (the TLS-at-ingress sanity check)
ROUTE=$(oc get route keycloak -n thatdot-openshift -o jsonpath='{.spec.host}')
curl -sk "https://$ROUTE/realms/quine-enterprise/.well-known/openid-configuration" | \
    jq '.issuer, .authorization_endpoint'
# Both must start with "https://$ROUTE/..." — NOT http://, NOT internal service name

# Retrieve admin username + password and log into admin console.
# RHBK 26.4 names the initial admin `temp-admin` (not `admin` as in older versions).
# Both values live in the keycloak-initial-admin Secret — always read both, don't assume username.
oc get secret keycloak-initial-admin -n thatdot-openshift -o jsonpath='{.data.username}' | base64 -d ; echo
oc get secret keycloak-initial-admin -n thatdot-openshift -o jsonpath='{.data.password}' | base64 -d ; echo
open "https://$ROUTE"
# Browser: log in with the username + password from above
# Confirm: 'quine-enterprise' realm visible in dropdown; 6 client roles; 6 test users

# Test user can log in via realm's account console
open "https://$ROUTE/realms/quine-enterprise/account"
# Log in as 'admin1' / 'placeholder123' → forced to change password → lands in account console

# Service-account CLI client can mint a bearer token with the right role claim
# (proves the qe-cli-* clients + role mappings are wired correctly)
KC_POD=$(oc get pod -n thatdot-openshift -l app=keycloak -o jsonpath='{.items[0].metadata.name}')
ADMIN_USER=$(oc get secret keycloak-initial-admin -n thatdot-openshift -o jsonpath='{.data.username}' | base64 -d)
ADMIN_PW=$(oc get secret keycloak-initial-admin -n thatdot-openshift -o jsonpath='{.data.password}' | base64 -d)
# Pass password via env (don't shell-interpolate — handles special characters safely).
oc exec -n thatdot-openshift "$KC_POD" -- env ADMIN_PW="$ADMIN_PW" /bin/bash -c \
    "/opt/keycloak/bin/kcadm.sh config credentials --server http://localhost:8080 --realm master --user $ADMIN_USER --password \"\$ADMIN_PW\""
# Get the qe-cli-admin client secret:
CLI_ID=$(oc exec -n thatdot-openshift "$KC_POD" -- \
    /opt/keycloak/bin/kcadm.sh get clients -r quine-enterprise -q clientId=qe-cli-admin --fields id --format csv --noquotes | tail -n1)
CLI_SECRET=$(oc exec -n thatdot-openshift "$KC_POD" -- \
    /opt/keycloak/bin/kcadm.sh get "clients/$CLI_ID/client-secret" -r quine-enterprise --fields value --format csv --noquotes | tail -n1)
# Use it to request a token via client_credentials grant:
TOKEN=$(curl -sk -d "client_id=qe-cli-admin" -d "client_secret=$CLI_SECRET" \
    -d "grant_type=client_credentials" \
    "https://$ROUTE/realms/quine-enterprise/protocol/openid-connect/token" | jq -r .access_token)
# Decode the JWT payload and confirm the 'admin' role is present:
echo "$TOKEN" | cut -d. -f2 | base64 -d 2>/dev/null | jq '.resource_access["quine-enterprise-client"].roles, .iss'
# Expected: ["admin"]  and  "https://$ROUTE/realms/quine-enterprise"
# (Repeat with qe-cli-billing to confirm role isolation — token should contain ["billing"], not ["admin"])

# THE WIN CONDITION — realm + users + roles + service-account clients survive Keycloak pod restart
oc delete pod -n thatdot-openshift -l app=keycloak
# Wait for new pod (oc get pods -w), re-open https://$ROUTE in browser:
#   - Realm 'quine-enterprise' STILL there
#   - 6 users STILL there
#   - 6 roles STILL there
# Proves: realm config lives in Postgres (not in Keycloak's pod-local H2 fallback)

# Re-mint a qe-cli-* token after the restart — still works, same claims.
```

**Done when** the discovery doc serves `https://`-prefixed URLs (TLS-at-ingress configured correctly), the admin console shows the realm with 6 client roles, 6 interactive users, and 6 service-account CLI clients, a test user can log in via the account console, a `client_credentials` grant against `qe-cli-admin` returns a JWT carrying `roles: ["admin"]`, *and* all of the above survive a Keycloak pod restart. All six Applications report `Synced + Healthy`.

**README addendum** "Step 5: Keycloak with quine-enterprise realm" — covers RHBK Operator + CNPG operator install, the edge-Route + `hostname.hostname` + `proxy.headers: xforwarded` pattern, where to retrieve the admin password, the password-reset-on-first-login flow for test users, and the pod-restart persistence test.

---

### Step 6 — Wire QE RBAC against Keycloak

**Goal:** Connect QE's OIDC config to Keycloak; verify role-based access end-to-end.

**Architectural placement:** Mostly config layer — edits inside existing leaves (`manifests/quine-enterprise/` and `manifests/keycloak/`) plus one new helper script. No new Application CRs, no new wrappers. ArgoCD picks up the changes automatically on commit + push.

**Architectural decisions baked in**

- **Truststore strategy: init-container builds JKS at pod startup; CA source is a script-populated ConfigMap.** QE's JVM has to trust Keycloak's TLS chain (cluster-wildcard cert signed by OpenShift's ingress-operator CA, NOT in the default JDK cacerts). Prior-art repos (`opstools/keycloak`, `thatdot-auth-services`) used pre-built JKS files mounted from a Secret — out-of-band setup that breaks each `crc delete` (CA regenerates). **First attempt** at our setup: use the `config.openshift.io/inject-trusted-cabundle: "true"` label so OpenShift's CNO populates the ConfigMap with the cluster trust bundle. **This failed in testing** — the inject label injects the cluster *Proxy* CA bundle (public CAs + corporate proxy CAs), NOT the cluster's own ingress-operator CA. curl `--cacert` against the resulting bundle returns `SSL certificate problem: self-signed certificate in certificate chain`. **Working approach:** a small script (`scripts/create-cluster-ingress-ca-configmap.sh`, called from `bootstrap.sh`) extracts the ingress CA from `openshift-config-managed/default-ingress-cert` and creates a `cluster-ingress-ca` ConfigMap in `thatdot-openshift`. Same source as the existing `trust-crc-ca.sh` script (which lands the same CA in the macOS keychain for browser trust). An init container (`build-truststore`) then reads that ConfigMap's PEM, splits the multi-cert bundle via awk, and imports each cert via `keytool` into a copy of the system cacerts. Result: a JKS that trusts public CAs (from system cacerts → license server) and the cluster ingress CA (from the ConfigMap → Keycloak Route). The main QE container mounts the JKS via emptyDir and points the JVM at it via `-Djavax.net.ssl.trustStore=...`.

- **Realm-aware readiness probe.** Existing `wait-for-cassandra` uses bash `/dev/tcp` for a TCP-listening probe. For Keycloak, we need a stronger signal — both "Keycloak is up" AND "the realm has been imported." `curl -fsS --cacert /injected-ca/ca-bundle.crt https://<route>/realms/quine-enterprise/.well-known/openid-configuration` only returns 200 when both are true. We deliberately validate the cert chain (no `-k`) — same posture QE uses; catches truststore misconfiguration in the init container rather than later in QE's OIDC bootstrap.

- **Explicit OIDC URLs (no auto-discovery).** QE 0.5.3 doesn't support an OIDC `discovery-url` field; it requires `locationUrl`, `authorizationUrl`, `tokenUrl` set explicitly. All three point at the Keycloak Route's hostname (which must match the JWT `iss` claim Keycloak emits — see Keycloak's `hostname.hostname` setting in step 5).

- **Client secret retrieval is out-of-band, idempotent.** The `quine-enterprise-client` secret is operator-generated inside Keycloak at realm-import time; no GitOps-pure way to read it. `scripts/create-qe-oidc-client-secret.sh` runs `kcadm.sh` against the Keycloak pod to fetch the secret, creates the K8s Secret `quine-enterprise-oidc-credentials`. Called from `bootstrap.sh` after waiting on `KeycloakRealmImport.status.conditions[Done] == True`. Idempotent: skips if the Secret already exists, so re-runs of `bootstrap.sh` don't fight with an operator-rotated secret.

- **Realm import update means a realm reset.** Step 6 adds the QE Route URL to `quine-enterprise-client`'s `redirectUris`/`webOrigins`. `KeycloakRealmImport` is fire-once: editing the YAML doesn't trigger a re-import on the existing cluster. We accept the realm-reset to apply the change (`oc delete keycloakrealmimport quine-enterprise` → ArgoCD recreates → fresh import wipes user state including the password reset already done on `admin1`). For cold deploys, the new YAML is what gets imported first time. The "realm reset" gotcha is documented.

**What's added**
- `scripts/create-cluster-ingress-ca-configmap.sh` — extracts `openshift-config-managed/default-ingress-cert` (the cluster's ingress-operator CA bundle, same source as `trust-crc-ca.sh`) and applies it as `cluster-ingress-ca` ConfigMap in `thatdot-openshift`. Idempotent; re-runs handle CA regeneration after `crc delete` + `crc start`. Called from `bootstrap.sh` BEFORE the root Application is seeded, so the ConfigMap exists when QE pods schedule.
- `manifests/quine-enterprise/patches/build-truststore.yaml` — Kustomize patch adding the first init container. Image: `registry.access.redhat.com/ubi9/openjdk-21:latest` (has `keytool` + a clean cacerts). Awk-splits the `cluster-ingress-ca` PEM bundle (multi-cert), imports each cert into `/workspace/cacerts` via `keytool -importcert`. emptyDir-volume-shared with the main container.
- `manifests/quine-enterprise/patches/wait-for-keycloak.yaml` — Kustomize patch adding the third init container. Image: `registry.access.redhat.com/ubi9/ubi:latest` (has `bash` + `curl`; `ubi9-minimal` lacks curl). `curl -fsS --cacert /injected-ca/ca-bundle.crt https://<route>/realms/quine-enterprise/.well-known/openid-configuration` loop with `sleep 5`.
- `manifests/quine-enterprise/values.yaml` updates — `oidc.enabled: true` with explicit `provider.{locationUrl, authorizationUrl, tokenUrl}` + `loginPath: "auth"`; `client.existingSecret.name: quine-enterprise-oidc-credentials`; JVM args gain `-Djavax.net.ssl.trustStore=/opt/truststore/cacerts -Djavax.net.ssl.trustStorePassword=changeit -Djavax.net.ssl.trustStoreType=JKS`; new top-level `volumes:` (referencing the `cluster-ingress-ca` ConfigMap + an emptyDir `truststore`) and `volumeMounts:` (the main container reads the JKS at `/opt/truststore`).
- `manifests/quine-enterprise/kustomization.yaml` updates — `patches:` now lists three patches (build-truststore → wait-for-cassandra → wait-for-keycloak; that's the init-container execution order). The `cluster-ingress-ca` ConfigMap is intentionally NOT in `resources:` — its content is cluster state extracted by `bootstrap.sh`, not git state.
- `manifests/keycloak/keycloak-realm-import.yaml` updates — `quine-enterprise-client.redirectUris: ["https://quine-enterprise-thatdot-openshift.apps-crc.testing/*"]` and `.webOrigins: ["https://quine-enterprise-thatdot-openshift.apps-crc.testing"]`.
- `scripts/create-qe-oidc-client-secret.sh` — idempotent; queries Keycloak via `kcadm.sh` to extract the client secret, creates the K8s Secret with both `clientSecret`/`clientId` and `client-secret`/`client-id` keys (hedge against chart key-name conventions until verified empirically).
- `scripts/bootstrap.sh` updates — after seeding the root Application, polls `oc get keycloakrealmimport quine-enterprise -o jsonpath='{.status.conditions[?(@.type=="Done")].status}'` until `True` (15-min timeout, 10-s poll interval), then calls `create-qe-oidc-client-secret.sh`.

**Iteration ritual:** Step 6 modifies *two* leaves — `manifests/quine-enterprise/` (new ConfigMap, two new init-container patches, OIDC config in values.yaml) and `manifests/keycloak/` (client redirectUris/webOrigins in the realm-import). Both chains converge at root, so the on-branch set is: `root`, `application-platform`, `application-product`, `application-keycloak`, `application-quine-enterprise` — 5 spots. Only `application-cassandra` stays on `main`. Branch name: `configure-rbac`. Same 5 spots flip back to `main` on PR finale.

**Order of operations**

Step 6 is mostly additive against an already-running cluster, but the realm-import change requires a one-time reset.

1. *(Already done by Claude when files are written)* New files + edits as listed above; 5-spot branch-flip to `configure-rbac`.
2. Commit + push to `configure-rbac`.
3. **Force a realm re-import to pick up the new redirectUris.** On the running cluster:
   ```bash
   oc delete keycloakrealmimport quine-enterprise -n thatdot-openshift
   ```
   ArgoCD's auto-sync recreates the CR within ~30s; the operator runs a fresh import Job; test users' password resets are wiped along with everything else (re-prompted on next login).
4. Re-run bootstrap so the new wait-for-realm-import logic + secret creation kick in:
   ```bash
   ./scripts/bootstrap.sh
   ```
   Idempotent — re-applies the customizations patch, waits for the realm-import to be Done, calls `create-qe-oidc-client-secret.sh`. If the Secret already exists, no-op (so re-runs after a `oc delete keycloakrealmimport` produce no Secret churn; the client secret value stays stable across realm re-imports because Keycloak preserves it when re-importing the same client).
5. Force ArgoCD to refresh QE so the new manifests apply:
   ```bash
   oc annotate application quine-enterprise -n openshift-gitops argocd.argoproj.io/refresh=hard --overwrite
   ```
6. Watch QE pod roll. Three init containers run in order: build-truststore (~10s) → wait-for-cassandra (~5s on a healthy cluster) → wait-for-keycloak (~5s once the realm is up). Then main QE container starts with the new OIDC config + JVM truststore.
7. Verify (see below).
8. Finale: flip the 5 `targetRevision`s back to `main`, merge PR, post-merge `oc apply -f bootstrap/root-application.yaml` from main.

**Gotchas to know in advance**

- **Realm-import is fire-once.** Editing `keycloak-realm-import.yaml` and pushing won't change the running realm. Must `oc delete keycloakrealmimport quine-enterprise` to force a re-import. Step 6 hits this once for the redirectUris change. (See step 5 gotchas.)
- **Client secret stability across re-imports.** When the realm is re-imported, Keycloak preserves the client's secret (because we don't specify one in the YAML — operator-generated secrets persist across `OVERWRITE_EXISTING` reconciles). So the `quine-enterprise-oidc-credentials` K8s Secret stays valid after the realm reset. If a future change *does* invalidate the client secret, you'd need to delete the K8s Secret and re-run `create-qe-oidc-client-secret.sh`.
- **The trust-bundle ConfigMap uses a *label*, not an annotation.** Older OpenShift docs sometimes show annotation form; modern docs (4.10+) require the label `config.openshift.io/inject-trusted-cabundle: "true"`. We use the label form.
- **`keytool -importcert` only imports the FIRST cert in a multi-cert PEM file.** OpenShift's trust bundle typically has 2-3 concatenated certs. The build-truststore script awk-splits the bundle into individual files and imports each — that's the standard workaround.
- **Volume sharing between init and main containers.** The truststore JKS lives in an `emptyDir` volume defined at the pod level. The init container writes; the main container reads. Both reference the volume by name (`truststore`).
- **Chart's expected Secret key names.** Prior-art Helm values references `existingSecret.name` but doesn't document which keys the chart reads from it. We populate four key-name variants in the Secret (`clientId`/`clientSecret`/`client-id`/`client-secret`) — once verified empirically which the chart uses, the others can be dropped.
- **CRC apps domain hardcoded.** Three places carry `keycloak-thatdot-openshift.apps-crc.testing` / `quine-enterprise-thatdot-openshift.apps-crc.testing`: the Keycloak CR's hostname, the realm-import's redirectUris, and the wait-for-keycloak probe URL. Porting to a production cluster swaps `apps-crc.testing` for that cluster's `*.apps.<cluster>.<domain>` in all three.

**Verification**

```bash
# All Application CRs Synced + Healthy
oc get application -n openshift-gitops

# QE pod is Running with all init containers Completed
oc get pod -n thatdot-openshift -l app.kubernetes.io/name=quine-enterprise \
    -o custom-columns=NAME:.metadata.name,STATUS:.status.phase,INIT:.status.initContainerStatuses[*].name
# Expect: 3 init container names — build-truststore, wait-for-cassandra, wait-for-keycloak

# OIDC-related log lines from QE pod startup
oc logs -n thatdot-openshift -l app.kubernetes.io/name=quine-enterprise --tail=200 \
    | grep -iE 'oidc|keycloak|issuer'
# Expect: discovery URL resolved, JWKS fetched, no TLS handshake errors.

# Browser test — interactive OIDC flow
ROUTE=$(oc get route quine-enterprise -n thatdot-openshift -o jsonpath='{.spec.host}')
open "https://$ROUTE"
# Expect: redirected to Keycloak login. Log in as admin1 / placeholder123,
# reset password on first login, get redirected back to QE landing page.
# Confirm: roles visible in QE UI; admin endpoints accessible.
# Log out; log in as analyst1; confirm restricted view (no admin endpoints).

# Bearer-token test — service-account flow against QE API
# (uses the qe-cli-admin client + secret from Keycloak)
KC_POD=$(oc get pod -n thatdot-openshift -l app=keycloak -o jsonpath='{.items[0].metadata.name}')
ADMIN_USER=$(oc get secret keycloak-initial-admin -n thatdot-openshift -o jsonpath='{.data.username}' | base64 -d)
ADMIN_PW=$(oc get secret keycloak-initial-admin -n thatdot-openshift -o jsonpath='{.data.password}' | base64 -d)
KEYCLOAK_ROUTE=$(oc get route keycloak -n thatdot-openshift -o jsonpath='{.spec.host}')
CLI_SECRET=$(oc exec -n thatdot-openshift "$KC_POD" -- env ADMIN_PW="$ADMIN_PW" /bin/bash -c "
    /opt/keycloak/bin/kcadm.sh config credentials --server http://localhost:8080 --realm master --user $ADMIN_USER --password \"\$ADMIN_PW\" >/dev/null
    CID=\$(/opt/keycloak/bin/kcadm.sh get clients -r quine-enterprise -q exact=true -q clientId=qe-cli-admin --fields id --format csv --noquotes | tail -1 | tr -d '\r')
    /opt/keycloak/bin/kcadm.sh get \"clients/\$CID/client-secret\" -r quine-enterprise --fields value --format csv --noquotes | tail -1 | tr -d '\r'
")
TOKEN=$(curl -sk -d "client_id=qe-cli-admin" -d "client_secret=$CLI_SECRET" \
    -d "grant_type=client_credentials" \
    "https://$KEYCLOAK_ROUTE/realms/quine-enterprise/protocol/openid-connect/token" | jq -r .access_token)
curl -sk -H "Authorization: Bearer $TOKEN" "https://$ROUTE/api/v2/admin/standing-queries"
# Expect: 200 with JSON response (admin role authorizes admin endpoints).
```

**Done when** all four DoD bullets from the Jira ticket are satisfied:
- QE reachable via Route with TLS, configured to use Cassandra as persistor ✓ (step 3)
- OIDC login through Keycloak; logged-in user has expected role ✓ (this step)
- Ingest query + standing query running, persistence to Cassandra observable ✓ (verified once OIDC is in place)
- README walks another engineer through the same path ✓ (README addendum)

**README addendum** "Step 6: RBAC enabled" — final state. README is now the v1 deliverable.

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
- [x] **Step 2** — Quine Enterprise standalone (no persistor / in-memory, no RBAC)
- [x] **Step 3** — Cassandra added (cass-operator); QE persistor switched; persistence verified across pod restart
- [x] **Step 4** — App-of-apps refactor (clean-slate teardown + 3-level platform/product split; bootstrap.sh shrunk to seed-only)
- [x] **Step 5** — Keycloak deployed with `quine-enterprise` realm
- [ ] **Step 6** — QE RBAC wired against Keycloak

### Wrap-up
- [ ] README reads as a complete walk-through for a fresh engineer
- [ ] `IMPLEMENTATION_PLAN.md` reviewed and reflects what was actually done (or call out divergences)
- [ ] Jira QU-2539 closed; sub-issues closed or rolled forward
