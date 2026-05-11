# Claude Code context — thatdot-openshift

## What this is

Discovery + first implementation pass to deploy Quine Enterprise into Red Hat OpenShift, on a local OpenShift Local (formerly CRC) cluster. Tracking ticket: **[QU-2539](https://thatdot.atlassian.net/browse/QU-2539)**.

The canonical document is **[`IMPLEMENTATION_PLAN.md`](./IMPLEMENTATION_PLAN.md)** — read it first. It has prerequisites, a 6-step walking-skeleton plan with verification per step, and a TL;DR checklist at the bottom that tracks progress.

## Critical rules

- **This repo is public on GitHub.** Never commit license keys, admin passwords, customer details, internal cluster URLs, or TLS private material. Secrets flow in via env vars at deploy time → `oc create secret`. Manifests reference secrets by name only.
- **OpenShift-native lane is the deliberate choice.** When recommending tooling or patterns, default to OpenShift-native equivalents (Operators from OperatorHub, Routes, `service-ca`, OpenShift GitOps) rather than upstream patterns from `enterprise-oauth-reference`.
- **Manifest-driven, not UI-driven.** All cluster state — operator Subscriptions, Namespaces, ArgoCD Applications, RoleBindings, everything — is expressed as YAML in this repo and applied via `oc apply` (for `bootstrap/` items) or GitOps sync (for `manifests/`). The OperatorHub web console is a *discovery* tool only; never install something through clicks without committing the resulting manifest. This is what makes the eventual production deployment reproducible from a clone.
- **Semantic naming, not step-numbered.** Files and directories are named by what they *are*, not by which step introduced them. `application-quine-enterprise.yaml`, `manifests/quine-enterprise/`, `manifests/cassandra/`, etc. Step numbers live in branch names (`step-2-basic-qe`) and the `IMPLEMENTATION_PLAN.md`, never in repo paths. (Step 1 used `step-1` paths; that was a v1 mistake corrected during step 2.)
- **Walking-skeleton order matters.** Don't skip ahead from step N to step N+2. Each step's verification is the gate for the next.
- **Cross-service ordering uses sync-waves *and* `initContainer` probes — complementary layers, both required when there's a dependency.** Sync-waves (annotations on Application CRs and on resources within an Application) order what ArgoCD *applies* — Subscription before its CR-using Applications, platform wrapper before product wrapper, etc. They do *not* gate runtime readiness: ArgoCD reports "Healthy" before services are necessarily serving, and waves don't re-fire on later pod restarts. So every long-running workload that depends on another service MUST also ship an `initContainer` that probes the dep at runtime and exits 0 only once it's reachable. Canonical examples:
  - **TCP probe** for "is the dep listening?" — `manifests/quine-enterprise/patches/wait-for-cassandra.yaml` uses bash `</dev/tcp/HOST/PORT` against `quine-dc1-service:9042`. Good for services where listening means ready (Cassandra accepts CQL connections only when fully bootstrapped).
  - **Application-layer probe** for "is the dep AND its config ready?" — `manifests/quine-enterprise/patches/wait-for-keycloak.yaml` (step 6) curls `/realms/quine-enterprise/.well-known/openid-configuration`. The discovery endpoint only returns 200 when both Keycloak is up AND the realm exists, so one probe covers both the service and the data dependency. Prefer application-layer probes when the readiness signal needs to include "the operator finished its reconcile job," not just "the pod is listening."
  - **Both patterns are resilient to *subsequent* dep outages** — every pod restart re-probes, so QE waiting for Keycloak after a Keycloak pod bounce just works.

## Architectural decisions (locked in)

| Decision | Choice | Rationale |
|---|---|---|
| Local cluster | OpenShift Local (CRC) | Same OCP bits as a production OpenShift cluster |
| GitOps engine | OpenShift GitOps Operator | Red Hat–native; the standard OpenShift GitOps path |
| TLS source | OpenShift `service-ca` (in-cluster) + default Route edge cert | Zero-install; no PEM material in public repo |
| Cassandra auth | None (`AllowAllAuthenticator`) | Out of v1 scope; defer JWT auth |
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

## File layout

```
IMPLEMENTATION_PLAN.md       # canonical plan + checklist (start here)
README.md                    # external-facing entry point
CLAUDE.md                    # this file
.gitignore                   # secret-shaped patterns blocked
.pre-commit-config.yaml      # gitleaks hook

bootstrap/                   # Applied directly with `oc apply` (NOT GitOps-synced).
                             # Means: "applied imperatively because GitOps can't (yet) manage it."
                             # Four files only:
  gitops-operator-subscription.yaml   # OpenShift GitOps Operator install (chicken-and-egg: ArgoCD can't manage its own install)
  argocd-customizations.yaml          # ArgoCD CR patch: --enable-helm + CassandraDatacenter Lua health check
  namespace-thatdot-openshift.yaml    # Shared workload namespace + managed-by label.
                                      # Preconditional — operator-provisioned RoleBinding must exist
                                      # before ArgoCD syncs into the namespace; secrets need it too.
  root-application.yaml               # Single seed; ArgoCD takes over from here.

manifests/                   # GitOps-synced. The 3-level app-of-apps tree:
                             #   root --> platform (wave 0) --> cass-operator + cassandra leaf
                             #        \-> product  (wave 1) --> quine-enterprise leaf
  root/                      # What root-application.yaml syncs.
    kustomization.yaml       #   resources: [application-platform.yaml, application-product.yaml]
    application-platform.yaml   # sync-wave "0"; itself an app-of-apps over manifests/platform/
    application-product.yaml    # sync-wave "1"; itself an app-of-apps over manifests/product/

  platform/                  # ArgoCD Apps for platform/infra workloads.
                             # Only Application CRs live here — operator subs live INSIDE each leaf.
                             # See "single-Application boundary" pattern note below.
    kustomization.yaml
    application-cassandra.yaml        # ArgoCD App for the Cassandra stack    (sync-wave "1")
    application-keycloak.yaml         # ArgoCD App for the Keycloak stack     (sync-wave "1")

  product/                   # ArgoCD Apps for differentiating workloads.
                             # Future home of Novelty, etc.
    kustomization.yaml
    application-quine-enterprise.yaml

  # Single-Application boundary pattern (adopted step 5; applies to every platform-layer leaf):
  # operators + workload CRs together in one leaf, ordered by sync-wave annotations.
  # `oc delete application <name>` recreates the whole stack cold. Same rule for both leaves.

  cassandra/                 # LEAF: synced by manifests/platform/application-cassandra.yaml.
    kustomization.yaml
    cass-operator-subscription.yaml   # Subscription, sync-wave "0"
    serviceaccount.yaml               # anyuid RoleBinding, sync-wave "0" (see step 3 SCC gotcha)
    cassandradatacenter.yaml          # CassandraDatacenter CR, sync-wave "1"

  keycloak/                  # LEAF: synced by manifests/platform/application-keycloak.yaml.
                             # KeycloakRealmImport is fire-once at the operator level, but the
                             # Pre/PostSync hook pair below makes realm-config iteration a single
                             # git commit. `oc delete application keycloak` remains the cold-restart
                             # primitive (for full-stack debug); not needed for routine realm edits.
    kustomization.yaml
    hooks-rbac.yaml                   # SA + Role + RoleBinding for the two hooks below.
                                      # PreSync,PostSync hook at sync-wave "-1" so the SA exists
                                      # before the wave-0 hook Jobs need it on the first sync.
    pre-sync-realm-reset.yaml         # PreSync hook (wave "0"): kcadm-deletes the realm and `oc
                                      # delete keycloakrealmimport`. Idempotent on first install
                                      # (no-ops if Keycloak isn't up yet). Required because the
                                      # operator's `kc.sh import --override=false` skips when the
                                      # realm exists (see KeycloakRealmImport gotcha below).
    rhbk-operator-subscription.yaml   # Subscription, sync-wave "0"
    postgres.yaml                     # Bare Postgres: PVC + Deployment + Service, sync-wave "1"
                                      # (CNPG was the original plan; pivoted because "cloud-native-postgresql"
                                      # in OperatorHub is EDB's paid product — see step 5 gotchas.)
    keycloak.yaml                     # RHBK Keycloak CR, sync-wave "2"
    route.yaml                        # edge-terminated Route, sync-wave "2"
    keycloak-realm-import.yaml        # KeycloakRealmImport CR, sync-wave "3"
    post-sync-pin-client-secret.yaml  # PostSync hook (wave "0"): kcadm-overwrites the operator-
                                      # generated quine-enterprise-client.secret with the value
                                      # from the quine-enterprise-oidc-credentials Secret.
                                      # Inverts the dependency: K8s Secret is source of truth,
                                      # Keycloak is reconciled to match. Result: re-imports
                                      # don't rotate the client_secret QE consumes.

  quine-enterprise/          # LEAF: synced by manifests/product/application-quine-enterprise.yaml.
    kustomization.yaml       #   helmCharts: QE 0.5.3
                             #   resources:  route.yaml
                             #   patches:    build-truststore, wait-for-cassandra, wait-for-keycloak
    values.yaml              # OIDC enabled, JVM truststore args, cluster-ingress-ca + emptyDir vols
    route.yaml
    patches/
      build-truststore.yaml     # initContainer 1: keytool-builds a JKS from system cacerts +
                                # the cluster ingress CA. Writes to emptyDir /workspace.
      wait-for-cassandra.yaml   # initContainer 2: blocks until Cassandra accepts CQL.
                                # Canonical TCP-probe pattern.
      wait-for-keycloak.yaml    # initContainer 3: cert-validating HTTPS probe to the realm
                                # OIDC discovery endpoint. Canonical application-layer-probe
                                # pattern (checks dep AND its config in one HTTP call).

# NB: the `cluster-ingress-ca` ConfigMap that build-truststore + wait-for-keycloak
# mount is NOT in this tree — it's populated by
# scripts/create-cluster-ingress-ca-configmap.sh at bootstrap time. Its source
# (openshift-config-managed/default-ingress-cert) is cluster state, not git state.

scripts/                     # Helper scripts (idempotent)
  bootstrap.sh               # Install GitOps Operator + patch ArgoCD + namespace + secrets + seed root
  trust-crc-ca.sh            # Trust CRC ingress CA in macOS keychain (Chrome/Safari)
  create-license-secret.sh   # $QE_LICENSE_KEY → qe-license Secret
  create-thatdot-registry-pull-secret.sh   # $THATDOT_REGISTRY_* → thatdot-registry-creds Secret
  create-keycloak-postgres-secret.sh       # random password → keycloak-postgres-app Secret
                                           # (idempotent — preserves existing password on re-run)
  create-qe-oidc-credentials-secret.sh     # Generates a random client_secret and creates the
                                           # quine-enterprise-oidc-credentials Secret directly
                                           # (no Keycloak interaction). The post-sync-pin-client-
                                           # secret hook then pushes this value INTO Keycloak,
                                           # so the K8s Secret is the source of truth. Called
                                           # from bootstrap.sh BEFORE seeding root (so the hook
                                           # has the Secret to read when it fires). Idempotent —
                                           # preserves existing value on re-run.
  create-cluster-ingress-ca-configmap.sh   # extracts openshift-config-managed/default-ingress-cert
                                           # into a `cluster-ingress-ca` ConfigMap in thatdot-openshift.
                                           # QE's truststore init container imports from this. Not
                                           # GitOps-managed because the source is cluster state.
```

## Useful gotchas

The first four entries are inherited from `enterprise-oauth-reference`; the rest were discovered live during steps 1–6 and are the primary reason this repo is more reliable to reproduce than the prior art.

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
- **`KeycloakRealmImport` is create-only against an empty realm slot — automated via Pre/PostSync hooks.** The fundamental constraint: even after deleting and recreating the CR, the import Job's hardcoded `kc.sh import --override=false` finds the existing realm and logs "Import skipped." The CRD exposes no `strategy` field; verified against upstream main (`operator/src/main/java/.../KeycloakRealmImportJobDependentResource.java:170-176`) — Keycloak has had years to add `OVERWRITE_EXISTING` and has not. We work around this with two ArgoCD hooks on the `keycloak` Application:
  - `manifests/keycloak/pre-sync-realm-reset.yaml` runs before each sync, kcadm-deletes the realm, and `oc delete keycloakrealmimport`. Idempotent on first install (no-ops if Keycloak isn't running yet).
  - `manifests/keycloak/post-sync-pin-client-secret.yaml` runs after sync, kcadm-overwrites the operator-generated `quine-enterprise-client.secret` with the value from the `quine-enterprise-oidc-credentials` K8s Secret.
  - Net effect: edit `manifests/keycloak/keycloak-realm-import.yaml`, commit, ArgoCD syncs. QE keeps serving across the re-import because the K8s Secret (QE's source of truth) never changes — only Keycloak's copy gets reconciled.
  - Manual fallbacks for when ArgoCD isn't doing the work: (a) **surgical** — `kcadm.sh delete realms/<name>` then `oc delete keycloakrealmimport quine-enterprise`; (b) **heavy** — `oc delete application keycloak` to cascade-delete the whole stack. After either, force a sync (`argo-sync keycloak` if you have the shell function, otherwise `oc patch application keycloak ... operation`) to re-trigger the hook pair.
- **`KeycloakRealmImport.spec.placeholders` does NOT actually substitute placeholders in the realm JSON.** Looks tempting — the spec field exists, the docs imply it works for secrets, the operator does inject the env vars on the import Job pod. BUT the operator's hardcoded `kc.sh import --override=false` command does not enable Keycloak's placeholder-substitution SPI, so `${VAR}` patterns in the realm JSON are imported as literal strings. Verified against upstream main and Keycloak issue [#26275](https://github.com/keycloak/keycloak/issues/26275) (closed 2024 with an unhelpful "got it to work, moved things around" comment but no fix to the operator command). Do not try to pin `quine-enterprise-client.secret` via `spec.placeholders` — use the post-sync kcadm reconciliation pattern above instead.
- **Operator-CRD chicken-and-egg in single-Application leaves.** When an Application contains both a Subscription (wave 0) and a CR whose CRD that Subscription installs (wave 1+), ArgoCD's pre-flight dry-run fails on the CR ("no matches for kind …") *before* wave 0 even gets a chance to install the operator — fails the whole sync after 5 retries. **Fix:** annotate the CRD-dependent resource with `argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true`. Sync-waves still order the apply correctly; this just disables the pre-flight validation that aborts the whole sync prematurely. Applied to: `CassandraDatacenter`, `Keycloak`, `KeycloakRealmImport`.
- **Orphan-CSV deadlock after `oc delete application` cascade — and recovery is racy.** When the cascade deletes a Subscription, the CSV stays (OLM owns it, not ArgoCD). On Application recreate, OLM's resolver hits `ConstraintsNotSatisfiable: CSV exists and is not referenced by a subscription, subscription exists, subscription requires the CSV` — a deadlock where the orphan blocks the new Subscription from adopting it. Symptom: Subscription stuck `ResolutionFailed=True`, dependent waves never apply, ArgoCD goes into retry-backoff (`Retrying attempt #5`). **Naive recovery (delete the CSV) often fails** because the InstallPlan stays around and OLM's reconciler recreates the CSV before the Subscription can be re-resolved, putting you right back in the deadlock. **Correct recovery sequence:** (1) `oc delete subscription <name> -n <ns>` (2) `oc delete installplan -n <ns> --all` (3) `oc delete csv <csv-name> -n <ns>` (4) wait ~30s for OLM to settle without the orphan being regenerated, (5) only THEN let ArgoCD recreate the Subscription via drift-detection or by triggering a manual sync on the parent Application. With ArgoCD's `selfHeal: true`, the parent Application may recreate the Subscription mid-cleanup — if that happens, deleting the whole **child** Application (`oc delete application <name>`) is the cleanest hammer: the resources-finalizer cascade clears OLM state in dependency order, then the **parent** Application's drift-detection recreates the child cleanly. Encountered live during step 6 debugging (hit three times before the right sequence stuck).
- **ArgoCD retry-backoff after 5 failed sync attempts requires explicit reset.** After 5 consecutive sync failures, ArgoCD backs the operation off ~10 min (`Retrying attempt #5 at <future-time>`). The `argocd.argoproj.io/refresh=hard` annotation does NOT reset the retry counter — it just invalidates the manifest cache. To force an immediate sync, set the Application's `operation` field directly: `oc patch application <name> -n openshift-gitops --type=merge -p '{"operation":{"sync":{"revision":"HEAD"},"initiatedBy":{"username":"manual"}}}'`. That's the `oc`-only equivalent of `argocd app sync` from the CLI.
- **QE's `roles` JWT claim is read at the JWT ROOT, not nested.** `AccessTokenClaims.decoder` in `quine-auth` does `c.downField("roles").as[Set[...]]` — a flat top-level claim. The Keycloak protocol mapper `oidc-usermodel-client-role-mapper` puts roles wherever `claim.name` specifies. **Must set `claim.name: "roles"`, NOT `claim.name: "resource_access.<client>.roles"` or any other nested path.** If nested: `/api/v2/auth/me` returns 401 with body `"CouldNotDecodeClaim(DecodingFailure at .roles: Missing required field)"`, and QE's `AuthenticationWrapper` redirects to `/api/v2/auth/login` immediately, creating a tight loop that looks like "the login isn't sticking." Symptom is indistinguishable from cookie problems — only the JSON body reveals it. See `manifests/keycloak/keycloak-realm-import.yaml` for all 7 protocolMappers (1 interactive + 6 service-account CLI clients) using the correct top-level `"roles"`.
- **OperatorHub catalog gotcha: "cloud-native-postgresql" is EDB's commercial product.** The `cloud-native-postgresql` package in `certified-operators` is EDB Postgres for Kubernetes, NOT upstream CloudNativePG. Pulls from `docker.enterprisedb.com` and requires a paid subscription. Step 5 originally planned to use it; pivoted to bare Postgres Deployment (see `manifests/keycloak/postgres.yaml`) when this surfaced. If you need an operator-managed Postgres on OpenShift, the free alternative is `crunchy-postgres-operator` — different CR schema, mandatory pgBackRest config. Always verify with `oc describe packagemanifest <pkg> -n openshift-marketplace` and check the actual image registry before committing a Subscription.
- **Red Hat container images with a pinned `USER` directive need `fsGroup` to write to PVCs.** Images like `registry.redhat.io/rhel9/postgresql-16` declare `USER 26` (postgres). With OpenShift's `restricted-v2` SCC, UID 26 is outside the namespace's allowed range, so admission falls back to `anyuid` (which the `default` SA has from cass-operator's RoleBinding). The container runs as UID 26, but a freshly-bound PVC is owned `root:root` mode 755 — UID 26 can't write. Symptom: `mkdir: cannot create directory '/var/lib/pgsql/data/userdata': Permission denied`. **Fix:** set `securityContext.fsGroup: <image's GID>` on the pod; Kubernetes chowns the PVC mount to that group on attach. Pin `runAsUser`/`runAsGroup` explicitly too — makes SCC selection deterministic rather than relying on implicit fall-through. See `manifests/keycloak/postgres.yaml`.
- **RHBK ships an older `apiVersion` than upstream Keycloak Operator.** Upstream Keycloak 26 uses `k8s.keycloak.org/v2beta1`; Red Hat Build of Keycloak 26.4 still serves only `k8s.keycloak.org/v2alpha1`. The kinds and field names are identical between versions, just the `apiVersion` differs. Symptom if you copy from upstream docs: `no matches for kind "Keycloak" in version "k8s.keycloak.org/v2beta1"` at apply time, even though the CRD exists. **Always verify with** `oc get crd keycloaks.k8s.keycloak.org -o jsonpath='{.spec.versions[*].name}{"\n"}'` before writing manifests against an operator you haven't used before.
- **ArgoCD operations can deadlock when sync-waves wait on never-Healthy resources.** With sync-waves + automated sync, ArgoCD applies wave N and waits for all wave-N resources to be Healthy before applying wave N+1. If a wave-N resource enters CrashLoopBackOff, the operation hangs in `operationState.phase: Running` forever — and ArgoCD won't pick up new manifest edits because the current operation is still "in progress." Symptom: `oc get application <name> -o jsonpath='{.status.sync.revision}'` shows the latest Git commit, but the resource on cluster still has the old spec. **Fix:** terminate the stuck operation with `oc patch application <name> -n openshift-gitops --type=merge -p '{"operation":null}'`, then ArgoCD's automated sync picks up the new manifests on its next cycle (force with `argocd.argoproj.io/refresh=hard` annotation if impatient).
- **`KeycloakRealmImport` does NOT auto-assign `default-roles-<realm>` to imported users.** Users created via Keycloak's admin UI auto-get the `default-roles-<realm>` composite role, which carries `view-profile` + `manage-account` from the built-in `account` client (plus `offline_access`, `uma_authorization`). Users created via `KeycloakRealmImport` do NOT. Symptom: user can log in (sees password-change prompt etc.), but the account console at `/realms/<realm>/account` shows "Something went wrong" because the SPA gets 401 on `/account/?userProfileMetadata=true` (token has no `view-profile`). **Fix:** every user in the realm-import YAML needs `realmRoles: [default-roles-<realm>]` next to its `clientRoles:` block. See `manifests/keycloak/keycloak-realm-import.yaml` for the canonical pattern.
- **`kcadm.sh get users -q username=X` does PARTIAL MATCH by default — devastating when usernames are substrings of each other.** Querying `username=admin1` will return BOTH `admin1` AND `superadmin1` (because "admin1" is a substring of "superadmin1"). `tail -1` non-deterministically picks one, leading to operations silently hitting the wrong user. **Fix:** always pass `-q exact=true` when looking up users by username: `kcadm.sh get users -r <realm> -q exact=true -q username=admin1`. Same applies to direct REST calls against the admin API — the `/users` endpoint defaults to fuzzy/substring match unless `exact=true` is in the query string. This bit us hard during the step-5 realm-import debugging — half a session of "the import has a role-mapping bug" was actually fuzzy-match hitting the wrong user.
- **QE's OIDC `redirect_uri` is generated from `quine.webserver-advertise.*`, not the request's `Host` header.** Behind an edge-terminated OpenShift Route, QE's pod sees plain HTTP on port 8080 and bakes that into the redirect_uri (`http://...apps-crc.testing/api/v2/auth/callback`) — Keycloak then rejects the login because the realm doesn't register that form. Fix is THREE JVM args (all required, all on QE 1.10.6+):
  ```
  -Dquine.webserver-advertise.address=<route hostname>
  -Dquine.webserver-advertise.port=443
  -Dquine.webserver-advertise.use-tls=true
  ```
  Same TLS-at-ingress family as the Keycloak `hostname.hostname` + `proxy.headers: xforwarded` gotcha — both Keycloak and QE need to be told what URL the *browser* sees. `use-tls=true` is the new (1.10.6) flag that flips the generated URL scheme to `https://`; older QE versions don't have it.
- **QE 1.10.6 emits `:443` explicitly in the redirect_uri even though it's the HTTPS default port.** Result: redirect_uri is `https://host:443/api/v2/auth/callback`, which doesn't match `https://host/*` in Keycloak's literal-string + path-wildcard validation. Register BOTH forms in the realm import's `redirectUris` (and `webOrigins`): `https://host/*` AND `https://host:443/*`. Likely a QE bug worth filing upstream, but no knob for us today.
- **`config.openshift.io/inject-trusted-cabundle` injects *proxy CAs*, NOT the cluster's own ingress-operator CA.** This trips you up the first time. The label-injected bundle is the cluster Proxy's `additionalTrustBundle` (which on bare CRC is just public Mozilla CAs, on a corporate cluster has whatever proxy CAs are configured). The cluster's *own* ingress CA — the one signing every `*.apps.<cluster>.<domain>` Route — lives separately at `openshift-config-managed/default-ingress-cert`. If a pod needs to validate a Route's TLS chain, neither `inject-trusted-cabundle` nor `service.beta.openshift.io/inject-cabundle` (which is for service-ca) covers it. Use the same source as `scripts/trust-crc-ca.sh`: extract `openshift-config-managed/default-ingress-cert` and write it to a namespaced ConfigMap (see `scripts/create-cluster-ingress-ca-configmap.sh`). Symptom of getting this wrong: `curl --cacert <bundle> https://<route>` returns `SSL certificate problem: self-signed certificate in certificate chain`.
- **`keytool -importcert` only imports the FIRST cert in a multi-cert PEM file.** OpenShift trust bundles typically have 2-3 certs concatenated. Use awk to split into individual files, loop `keytool -importcert` per file. Canonical pattern: `manifests/quine-enterprise/patches/build-truststore.yaml`.
- **QE role names in the realm must be exact PascalCase: `SuperAdmin`, `Admin`, `Architect`, `DataEngineer`, `Analyst`, `Billing`.** `quine-auth/.../Role.scala`'s `fromReferenceOrName` is a plain case-sensitive string match against those six references with no case-folding, no aliasing, no separator normalization. `superadmin`, `super-admin`, `super_admin`, `SUPERADMIN`, `dataengineer` — all silently discarded by the decoder, then `.flatten`'d out of the resulting `Set[Role]`. Symptom: login succeeds, `/api/v2/auth/me` returns 200 with `"roles":[], "permissions":[]`, and QE pod logs show `WARN ... Discarding unknown role name: <whatever>`. Distinct from the `claim.name` nested bug (which produces an infinite redirect loop instead). Both bugs are realm-config; both produce broken authorization; this one is the quiet/stealth variant. See `docs/OIDC_REDIRECT_LOOP_POSTMORTEM.md` for the full write-up of both.

## When you finish a piece of work

- Update `IMPLEMENTATION_PLAN.md`: cross off the relevant TL;DR checklist item; if you diverged from the plan, edit the affected step rather than letting the plan drift.
- Add the corresponding section to `README.md` so the README is a real walk-through, not a stub.
- Verify nothing secret-shaped is staged before committing (`git diff --cached`).
