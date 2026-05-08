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
- [x] **Step 2** — Quine Enterprise standalone (no persistor / in-memory, no RBAC)
- [x] **Step 3** — Cassandra added (cass-operator); QE persistor switched; persistence verified across pod restart
- [ ] **Step 4** — Keycloak deployed with `quine-enterprise` realm
- [ ] **Step 5** — QE RBAC wired against Keycloak

### Wrap-up
- [ ] README reads as a complete walk-through for a fresh engineer
- [ ] `IMPLEMENTATION_PLAN.md` reviewed and reflects what was actually done (or call out divergences)
- [ ] Jira QU-2539 closed; sub-issues closed or rolled forward
