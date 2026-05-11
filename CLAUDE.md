# Claude Code context — thatdot-openshift

## What this is

Reference deployment of Quine Enterprise into Red Hat OpenShift, targeting OpenShift Local (formerly CRC) for dev iteration. Tracking ticket: **[QU-2539](https://thatdot.atlassian.net/browse/QU-2539)**.

Two companion docs:
- **[`README.md`](./README.md)** — how to run this (prerequisites, bootstrap, iteration tips, diagnostics).
- **[`docs/ARCHITECTURE.md`](./docs/ARCHITECTURE.md)** — design rationale (the *why* behind non-obvious choices, per-stack briefs, cross-cutting patterns, known gaps for production).

This file is the *operational reference*: contributor conventions and a curated list of gotchas that bit us — grouped so you can scan for "is this my problem?"

## Critical rules

- **This repo is public on GitHub.** Never commit license keys, admin passwords, customer details, internal cluster URLs, or TLS private material. Secrets flow in via env vars at deploy time → `oc create secret`. Manifests reference Secrets by name only.
- **OpenShift-native lane is the deliberate choice.** Default to OpenShift-native equivalents (Operators from OperatorHub, Routes, `service-ca`, OpenShift GitOps) rather than upstream patterns.
- **Manifest-driven, not UI-driven.** All cluster state is YAML in this repo, applied via `oc apply` (for `bootstrap/`) or GitOps sync (for `manifests/`). The OperatorHub web console is a *discovery* tool only — never install through clicks without committing the resulting manifest.
- **Semantic naming, not step-numbered.** Files and directories are named by what they *are*, not by which step introduced them. Step numbers belong in branch names and git history, not repo paths.
- **Cross-service ordering uses sync-waves AND `initContainer` probes — complementary, both required.** Sync-waves order what ArgoCD applies; they don't gate runtime readiness or re-fire on pod restarts. Every long-running workload that depends on another service ships an `initContainer` that probes the dep at runtime and exits 0 once it's reachable. Canonical examples: `manifests/quine-enterprise/patches/wait-for-cassandra.yaml` (TCP probe via bash `</dev/tcp/HOST/PORT`) and `wait-for-keycloak.yaml` (application-layer probe — checks dep + its config in one HTTP call). Both re-probe on every pod restart, so subsequent dep outages are handled cleanly.

## Useful gotchas

### OpenShift SCC & pod identity

- **`restricted-v2` SCC assigns a random UID and forbids ports < 1024.** Helm charts pinning `runAsUser` will be rejected by admission — strip the field; let SCC pick.
- **Red Hat images with a pinned `USER` directive need `fsGroup` to write to PVCs.** E.g., `registry.redhat.io/rhel9/postgresql-16` declares `USER 26`. With `anyuid` SCC bound to the namespace's `default` SA, the container runs as UID 26 — but a freshly-mounted PVC is owned `root:root` mode 755. Fix: set `securityContext.fsGroup: <image's GID>` on the pod; Kubernetes chowns the mount on attach. Pin `runAsUser`/`runAsGroup` too for deterministic SCC selection. See `manifests/keycloak/postgres.yaml`.
- **`cass-operator` hardcodes UID/GID 999** on the Cassandra pod. `restricted-v2` rejects this with `unable to validate against any security context constraint`. Bind the namespace's `default` SA to the `anyuid` SCC via RoleBinding (see `manifests/cassandra/serviceaccount.yaml`).

### ArgoCD operations

- **Every namespace ArgoCD syncs into needs the `argocd.argoproj.io/managed-by: openshift-gitops` label.** OpenShift GitOps's default ArgoCD is namespace-scoped; the operator watches for this label and provisions the RoleBinding. Without it, sync fails `forbidden` on every namespaced resource.
- **Kustomize + `helmCharts:` requires `--enable-helm` on the ArgoCD instance.** Set in `bootstrap/argocd-customizations.yaml`. Without it, `helmCharts:` blocks render as empty — silent failure.
- **Operator-CRD chicken-and-egg in single-Application leaves.** When an Application contains both a wave-0 Subscription and a wave-1+ CR whose CRD that Subscription installs, ArgoCD's pre-flight dry-run fails on the CR (`no matches for kind …`) *before* wave 0 runs, and the whole sync aborts after 5 retries. Fix: annotate the CR with `argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true`. Applied to: `CassandraDatacenter`, `Keycloak`, `KeycloakRealmImport`.
- **ArgoCD retry-backoff after 5 failed syncs requires explicit reset.** The `argocd.argoproj.io/refresh=hard` annotation only invalidates the manifest cache — it does NOT reset the retry counter. Use `argo-sync <app>` (README helper) or `oc patch application <name> ... --type=merge -p '{"operation":{"sync":{},"initiatedBy":{"username":"manual"}}}'`.
- **`revision: "HEAD"` in a sync operation can resolve to a stale commit.** The literal string `"HEAD"` is interpreted inconsistently by ArgoCD's repo-server and can land on an older commit than the branch tip — even when `status.sync.revision` shows the latest. Prefer `sync:{}` (omit revision — ArgoCD uses `spec.source.targetRevision`) or pass an explicit SHA. The `argo-sync` / `argo-sync-here` helpers in the README take care of this.
- **Sync operations can hang when sync-waves wait on never-Healthy resources.** A wave-N CrashLoopBackOff hangs `operationState.phase: Running` forever; new manifest edits aren't picked up. Fix: `oc patch application <name> -n openshift-gitops --type=merge -p '{"operation":null}'`, then re-sync.
- **Orphan-CSV deadlock after `oc delete application` cascade.** The cascade deletes the Subscription but OLM keeps the CSV; on re-create, OLM hits `ConstraintsNotSatisfiable`. Recovery: `oc delete subscription <name>`, `oc delete installplan -n <ns> --all`, `oc delete csv <csv-name>`, wait ~30s for OLM to settle, THEN let ArgoCD recreate. With `selfHeal: true`, the parent App may recreate the Subscription mid-cleanup — if that happens, delete the **child** Application instead (cascade clears OLM state in dep order; parent's drift-detection recreates cleanly).

### Keycloak operator + realm

- **RHBK serves `k8s.keycloak.org/v2alpha1`, not v2beta1.** Upstream Keycloak 26 uses v2beta1; RHBK 26.4 still ships v2alpha1. Kinds + fields identical; only the version string differs. Symptom from copy-pasting upstream docs: `no matches for kind "Keycloak" in version "k8s.keycloak.org/v2beta1"`. Verify with `oc get crd keycloaks.k8s.keycloak.org -o jsonpath='{.spec.versions[*].name}'`.
- **QE's `roles` JWT claim is read at the JWT ROOT, not nested.** QE's decoder does `c.downField("roles").as[Set[...]]`. The protocol mapper `oidc-usermodel-client-role-mapper` emits to whatever `claim.name` specifies. Must be `claim.name: "roles"` — NOT `"resource_access.<client>.roles"` or any other nested path. If nested: infinite redirect loop, `CouldNotDecodeClaim(DecodingFailure at .roles: Missing required field)` in `/api/v2/auth/me`'s 401 body.
- **Role names must be exact PascalCase: `SuperAdmin`, `Admin`, `Architect`, `DataEngineer`, `Analyst`, `Billing`.** `quine-auth`'s `Role.fromReferenceOrName` is case-sensitive exact-string match — no case-folding, aliasing, or separator normalization. Wrong values → login succeeds, `/api/v2/auth/me` returns 200 with `roles: []`. Stealth variant of the previous bug. Customer-facing diagnostic recipes: [`docs.thatdot.com/quine-enterprise/learn/oidc-setup`](https://docs.thatdot.com/quine-enterprise/learn/oidc-setup/).
- **`KeycloakRealmImport` does NOT auto-assign `default-roles-<realm>` to imported users.** Admin-UI-created users get it automatically; YAML-imported users don't. Symptom: user logs in fine but the account console at `/realms/<realm>/account` shows "Something went wrong" — the SPA gets 401 because the token lacks `view-profile`. Fix: every user in the realm-import YAML needs `realmRoles: [default-roles-<realm>]` next to its `clientRoles:` block.
- **`kcadm.sh get users -q username=X` is PARTIAL MATCH by default.** Querying `username=admin1` returns BOTH `admin1` AND `superadmin1` (substring match). `tail -1` non-deterministically picks one; operations silently hit the wrong user. Fix: always pass `-q exact=true` for username lookups. Same on direct REST calls against `/users`.

### KeycloakRealmImport mechanics

- **Create-only against an empty realm slot — automated via Pre/PostSync hooks.** Even after deleting and recreating the CR, the import Job's hardcoded `kc.sh import --override=false` finds the existing realm and logs "Import skipped." The CRD exposes no `strategy` field; verified against upstream main. We work around with two hooks on the `keycloak` Application:
  - `manifests/keycloak/pre-sync-realm-reset.yaml` — kcadm-deletes the realm and the CR before each sync. Idempotent on first install (no-ops if Keycloak isn't running yet).
  - `manifests/keycloak/post-sync-pin-client-secret.yaml` — kcadm-overwrites the operator-generated `quine-enterprise-client.secret` with the value from the `quine-enterprise-oidc-credentials` K8s Secret.
  - Net effect: edit `keycloak-realm-import.yaml`, commit, ArgoCD syncs. QE keeps serving — its session cookies and JWTs stay valid because the K8s Secret never changes; only Keycloak's copy is reconciled.
  - Manual fallbacks: (a) surgical — `kcadm.sh delete realms/<name>` then `oc delete keycloakrealmimport <name>`; (b) heavy — `oc delete application keycloak`. Force a sync afterward to re-trigger hooks.
- **`spec.placeholders` does NOT actually substitute placeholders in the realm JSON.** Looks tempting — the spec field exists, the operator injects env vars on the import Job pod. But the operator's hardcoded `kc.sh import` command doesn't enable Keycloak's placeholder-substitution SPI, so `${VAR}` patterns import as literal strings. Verified against upstream main and Keycloak issue [#26275](https://github.com/keycloak/keycloak/issues/26275). Pin secrets via the post-sync kcadm reconciliation pattern instead.

### TLS-at-ingress

The whole topology: browser sees HTTPS at the Route (cluster wildcard cert); router terminates TLS; pod sees plain HTTP. Both Keycloak and QE need to be told what URL the *browser* sees, otherwise generated redirect URIs and discovery doc URLs come out as `http://...:8080/...` and break.

- **Keycloak:** `hostname.hostname: https://<route>` + `proxy.headers: xforwarded`. Without these, the discovery doc serves `http://` URLs and JWT `iss` claims are wrong.
- **QE:** three JVM args (all required, all on 1.10.6+):
  ```
  -Dquine.webserver-advertise.address=<route-host>
  -Dquine.webserver-advertise.port=443
  -Dquine.webserver-advertise.use-tls=true
  ```
- **QE 1.10.6 emits `:443` explicitly in `redirect_uri`** even though it's the HTTPS default port. Keycloak's path-wildcard validation is literal-string and rejects `https://host:443/*` against `https://host/*`. Register BOTH forms in the realm's `redirectUris` and `webOrigins`.

### Truststore construction

- **`config.openshift.io/inject-trusted-cabundle` injects *proxy CAs*, NOT the cluster's own ingress CA.** The label-injected bundle is the cluster Proxy's `additionalTrustBundle` (public CAs + corporate proxy CAs). The ingress CA — the one signing every `*.apps.<cluster>.<domain>` Route — lives at `openshift-config-managed/default-ingress-cert`. Extract via `scripts/create-cluster-ingress-ca-configmap.sh`. Symptom of getting this wrong: `curl --cacert <bundle> https://<route>` returns `SSL certificate problem: self-signed certificate in certificate chain`.
- **`keytool -importcert` only imports the FIRST cert in a multi-cert PEM file.** OpenShift trust bundles typically have 2-3 concatenated certs. Awk-split into individual files, loop `keytool -importcert` per file. Canonical pattern: `manifests/quine-enterprise/patches/build-truststore.yaml`.

### Workload config (QE + Cassandra)

- **QE resource limits: `2Gi` request, `4Gi` limit, `-Xmx2g`.** Without these, JVM uses 25% of node RAM and OOM-kills.
- **Cassandra heap: cap to `512m`** — CRC has limited memory.
- **`--force-config` flag on QE** so it uses YAML persistor config rather than the recipe's default ephemeral RocksDB.
- **QE OIDC library (`oidc4s`) requires `https://` for the issuer URL** — non-negotiable. `service-ca` handles this for in-cluster TLS.
- **Moving image tags require `imagePullPolicy: Always`.** Tags like `:main` get repointed by the registry; `IfNotPresent` would serve the kubelet's stale cache forever. Pinned semver tags (`:0.5.3`) can stay `IfNotPresent`.
- **QE 0.5.3 chart supports `imagePullSecrets` natively** in `values.yaml`. No Kustomize patch needed.
- **Cassandra datacenter name comes from the CR's `metadata.name`** — keep Helm values' `cassandra.localDatacenter` aligned with whatever's in `manifests/cassandra/cassandradatacenter.yaml`.

## When you finish a piece of work

- Update `docs/ARCHITECTURE.md` if you introduced a new architectural decision, cross-cutting pattern, or gap-for-production item.
- Update `README.md` if you added a new operational pattern users will care about.
- Add to CLAUDE.md's gotchas only if it's a non-obvious behavior that bit you and would bite someone else — keep entries terse and put them in the right group.
- Verify nothing secret-shaped is staged before committing (`git diff --cached`).
