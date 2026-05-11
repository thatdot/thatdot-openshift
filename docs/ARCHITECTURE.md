# Architecture

Reference deployment of Quine Enterprise on Red Hat OpenShift. This document covers the *why* behind the design — for *how to run it*, see the [README](../README.md); for engineering gotchas and operational reference, see [CLAUDE.md](../CLAUDE.md).

## Overview

Three product components are deployed to a single namespace (`thatdot-openshift`) and wired together via OpenShift GitOps:

- **Cassandra** — persistor for Quine Enterprise, managed by `cass-operator` (k8ssandra community operator from OperatorHub).
- **Keycloak** — OIDC provider with a pre-configured `quine-enterprise` realm. Managed by the Red Hat Build of Keycloak (RHBK) operator; backed by a small Postgres Deployment.
- **Quine Enterprise** — installed from thatDot's Helm chart, configured for OIDC auth and Cassandra persistence.

All cluster state is expressed as YAML in this repo. `scripts/bootstrap.sh` seeds a single ArgoCD Application; ArgoCD owns everything from there.

### GitOps cascade

```
root  (bootstrap/root-application.yaml — the only seed)
 ├── application-platform   (wave 0)  →  manifests/platform/
 │     ├── application-cassandra      →  manifests/cassandra/
 │     │     ├── cass-operator-subscription                (wave 0)
 │     │     ├── default-SA anyuid RoleBinding             (wave 0)
 │     │     └── CassandraDatacenter                       (wave 1)
 │     │
 │     └── application-keycloak       →  manifests/keycloak/
 │           ├── hooks-rbac (SA + Role + RoleBinding)      (PreSync,PostSync wave -1)
 │           ├── pre-sync-realm-reset (Job)                (PreSync wave 0)
 │           ├── rhbk-operator-subscription                (wave 0)
 │           ├── postgres (PVC + Deployment + Service)     (wave 1)
 │           ├── Keycloak CR                               (wave 2)
 │           ├── Route (edge-terminated)                   (wave 2)
 │           ├── KeycloakRealmImport                       (wave 3)
 │           └── post-sync-pin-client-secret (Job)         (PostSync wave 0)
 │
 └── application-product    (wave 1)  →  manifests/product/
       └── application-quine-enterprise → manifests/quine-enterprise/
             ├── QE Helm chart (Kustomize helmCharts:)
             ├── Route (edge-terminated)
             └── 3 init-container patches
                   ├── build-truststore        (JKS from cluster ingress CA)
                   ├── wait-for-cassandra      (TCP probe)
                   └── wait-for-keycloak       (TLS-validating HTTP probe)
```

Three levels deep is the structural cap. Codefresh's research on Argo Application nesting is explicit: four-plus levels turns debugging into a multi-step traversal. If we outgrow this structure, the escape hatch is ApplicationSet at the wrapper layer rather than nesting deeper.

## Architectural decisions

### OpenShift GitOps Operator over vanilla ArgoCD

Red Hat ships an ArgoCD distribution as the "OpenShift GitOps" operator (installed via OperatorHub Subscription). It's the OpenShift-native lane — same ArgoCD bits underneath, but managed as a Kubernetes-native `ArgoCD` CR with built-in OpenShift integration (OAuth login via cluster identity, default RBAC scoped to a `managed-by` label). On a customer's production OpenShift cluster, this is how they install ArgoCD.

The default ArgoCD instance is namespace-scoped: it can only manage resources in namespaces labeled `argocd.argoproj.io/managed-by: openshift-gitops`. `bootstrap/namespace-thatdot-openshift.yaml` carries that label; the operator watches for it and provisions the necessary RoleBinding asynchronously.

### TLS strategy: cluster wildcard + service-ca

No cert-manager, no PEM material in this public repo. Two CAs are at play:

- **Cluster ingress CA** (the one signing the wildcard `*.apps.<cluster>.<basedomain>` cert) — terminates TLS at every Route's edge. Browsers see this; pods don't need to validate against it for routine work.
- **`service-ca`** (OpenShift's built-in CA for service-to-service in-cluster TLS) — annotation-driven, generates Secrets containing certs for pod-to-pod HTTPS when needed.

QE specifically needs to validate the cluster ingress CA's chain (to talk to Keycloak over HTTPS at its Route). That CA is *not* in the JVM's default cacerts, *not* in OpenShift's `inject-trusted-cabundle` ConfigMap (which carries proxy CAs, not the ingress CA — a tripping point), and *not* in `service.beta.openshift.io/inject-cabundle` (which is for service-ca). It lives in `openshift-config-managed/default-ingress-cert`. See [Cross-cutting patterns → JVM truststore construction](#jvm-truststore-construction).

### Keycloak DB: bare Postgres, not CloudNativePG

The OperatorHub `cloud-native-postgresql` package turns out to be EDB's commercial "EDB Postgres for Kubernetes" product — its operator pulls from `docker.enterprisedb.com` and requires a paid subscription. Curated OpenShift catalogs ship no upstream CNPG package. The free alternatives are `crunchy-postgres-operator` (different CR schema, mandatory pgBackRest config) or a bare Deployment.

We chose the bare path: `manifests/keycloak/postgres.yaml` is a `PVC + Deployment + Service` using `registry.redhat.io/rhel9/postgresql-16` (Red Hat's OpenShift-aware image; handles `restricted-v2` SCC and reads `POSTGRESQL_*` env vars). One non-operator workload in this otherwise operator-managed repo, but the trade-off was acceptable.

### Single-Application boundary per stack

Each leaf in `manifests/` owns its *whole* stack: the operator Subscription, any RBAC, and the workload CRs the operator reconciles. The Keycloak leaf even includes the realm-import CR.

The rule: an Application is the unit of "reset." `oc delete application keycloak -n openshift-gitops` recreates the whole Keycloak stack (operator, Postgres, Keycloak CR, realm) from cold. Same for Cassandra and QE. This makes ArgoCD-driven cascade-delete the natural debug primitive when something gets into a bad state.

Two operational notes:
- **Sync-waves order resources within an Application.** Inside the keycloak leaf: wave 0 = operator Subscription, wave 1 = Postgres, wave 2 = Keycloak CR + Route, wave 3 = realm import. The wrapper Applications (platform/product) use waves separately to order their children.
- **CRD chicken-and-egg requires `SkipDryRunOnMissingResource=true`** on any resource whose CRD a wave-0 Subscription installs. Without that annotation, ArgoCD's pre-flight dry-run fails on the CR ("no matches for kind") *before* wave 0 has a chance to install the operator, and the whole sync aborts after 5 retries. Applied to: `CassandraDatacenter`, `Keycloak`, `KeycloakRealmImport`.

### Custom Lua health checks for operator CRs

ArgoCD's built-in health checks know about Deployments, StatefulSets, Pods, Services, Routes — but not about third-party operator CRs. Without help, ArgoCD reports an Application Healthy as soon as the CR is *applied*, regardless of whether the operator has reconciled it. That makes sync-waves useless for cross-stack ordering: if Application B's wave-1 resource depends on Application A's wave-0 Custom Resource being *actually* reconciled (not just applied), and ArgoCD reports the CR Healthy on apply, B will start before A is ready.

`bootstrap/argocd-customizations.yaml` registers three custom checks:

| Kind | Healthy condition |
|---|---|
| `CassandraDatacenter` | `cassandraOperatorProgress == "Ready"` AND `conditions[Ready].status == "True"` |
| `Keycloak` | `conditions[Ready].status == "True"` AND `HasErrors == False` |
| `KeycloakRealmImport` | `conditions[Done].status == "True"` |

The KeycloakRealmImport check is what gates the timing of the PostSync `pin-client-secret` Job — it only fires once the realm import is genuinely done.

### Sync-waves + init-container probes are complementary

Sync-waves order what ArgoCD *applies*. Init-container probes gate what runs at *pod startup*. They solve different problems:

- **Sync-waves** order things at sync time (CRD before CR, operator before workload, platform before product). They don't re-fire when a pod restarts later.
- **Init-container probes** gate runtime readiness. If Keycloak's pod restarts mid-day, QE's `wait-for-keycloak` init container re-probes on its next pod start — the dependency holds.

Every long-running workload that depends on another service ships both:
- **TCP probe** for "is the dep listening?" — `manifests/quine-enterprise/patches/wait-for-cassandra.yaml` uses bash `</dev/tcp/HOST/PORT` against `quine-dc1-service:9042`. Good when "listening" implies "ready."
- **Application-layer probe** for "is the dep AND its config ready?" — `manifests/quine-enterprise/patches/wait-for-keycloak.yaml` curls `/realms/quine-enterprise/.well-known/openid-configuration`. The discovery endpoint only returns 200 when *both* Keycloak is up *and* the realm has been imported.

### Pinned client_secret + Pre/PostSync hooks

`KeycloakRealmImport` is permanently create-only — the operator's hardcoded `kc.sh import --override=false` skips when the realm already exists, and the CRD exposes no `strategy` field. Verified against upstream main; Keycloak has had years to add `OVERWRITE_EXISTING` and has not.

To make realm-config iteration a single git commit (rather than a multi-step manual procedure), the keycloak Application carries two ArgoCD hooks:

- **PreSync hook** (`manifests/keycloak/pre-sync-realm-reset.yaml`) — kcadm-deletes the realm and `oc delete keycloakrealmimport`. Idempotent on first install (no-ops if Keycloak isn't running yet). This frees the realm slot so the operator's `kc.sh import` finds an empty target.
- **PostSync hook** (`manifests/keycloak/post-sync-pin-client-secret.yaml`) — kcadm-overwrites the operator-generated `quine-enterprise-client.secret` with the value from the `quine-enterprise-oidc-credentials` K8s Secret.

The K8s Secret (generated at bootstrap with a random value, never touched again) is the source of truth for the client_secret; Keycloak is reconciled to match. This inverts the usual dependency: re-imports rotate Keycloak's auto-generated secret, but QE's view of the secret never changes. **QE keeps serving across realm re-imports** — its session cookies and JWTs are validated locally, and the client_secret it consumes is stable.

Why not use `KeycloakRealmImport.spec.placeholders` to pin the secret directly in the realm yaml? The operator's placeholders feature only injects env vars onto the import Job pod — it doesn't enable Keycloak's placeholder-substitution SPI, so `${VAR}` patterns in the realm JSON are imported as literal strings. Verified in operator source (`KeycloakRealmImportJobDependentResource.java:170-176`) and Keycloak issue #26275.

## Per-stack briefs

### Cassandra

- **Operator:** `cass-operator-community` from OperatorHub (`community-operators` catalog). OwnNamespace install in `thatdot-openshift`. Same Subscription pattern as RHBK.
- **Workload:** A single `CassandraDatacenter` CR (cluster `quine`, datacenter `dc1`, 1 node). Configured for `AllowAllAuthenticator` — QE talks to it plaintext, no auth.
- **SCC:** cass-operator hardcodes UID 999 on the Cassandra pod's `securityContext`. `restricted-v2` rejects this; `manifests/cassandra/serviceaccount.yaml` binds the namespace's `default` ServiceAccount to the `anyuid` SCC.
- **Resource sizing:** 512Mi JVM heap (`HEAP_SIZE` env var), 2Gi PVC. Tuned for CRC's tight memory envelope.
- **Dependency consumers:** QE's `wait-for-cassandra` init container TCP-probes `quine-dc1-service:9042`.

### Keycloak

- **Operator:** RHBK 26.4 (`rhbk-operator` from `redhat-operators` catalog). Note: RHBK still serves `k8s.keycloak.org/v2alpha1` even though upstream Keycloak Operator has moved to `v2beta1`. Verify before copying CRs from upstream docs.
- **Backing store:** Bare Postgres Deployment (see [Keycloak DB decision](#keycloak-db-bare-postgres-not-cloudnativepg)). Credentials in `keycloak-postgres-app` Secret, generated at bootstrap (random 32-char password, idempotent).
- **TLS-at-ingress:** `Keycloak.spec.hostname.hostname` = the full Route URL with `https://`; `proxy.headers: xforwarded` so Keycloak trusts the router's `X-Forwarded-Proto: https` and emits HTTPS URLs in the discovery doc and JWT `iss` claims despite seeing plain HTTP internally.
- **Realm:** `quine-enterprise`, declared in `manifests/keycloak/keycloak-realm-import.yaml`. Contains one interactive OIDC client, six client roles (PascalCase — see [Role-claim contract](#role-claim-contract-with-qe)), six interactive users (placeholder passwords, `temporary: true`), and six service-account clients (one per role; minted via `client_credentials` grant).
- **Realm iteration:** PreSync + PostSync hooks (see [decision](#pinned-client_secret--prepostsync-hooks)). Edit `keycloak-realm-import.yaml`, commit, ArgoCD syncs.
- **Initial admin password:** Operator generates `keycloak-initial-admin` Secret with `username` and `password` keys. RHBK 26.4 names the admin `temp-admin`, not `admin` — read both keys, don't hardcode.

### Quine Enterprise

- **Source:** Helm chart from `helm.thatdot.com`, pulled via Kustomize `helmCharts:` (requires `--enable-helm` on the ArgoCD instance, set in `bootstrap/argocd-customizations.yaml`).
- **Image:** `:main` tag with `imagePullPolicy: Always` (moving tag — `IfNotPresent` would serve a stale kubelet cache forever). Pulled from `registry.license-server.dev.thatdot.com` via `thatdot-registry-creds` pull secret (created at bootstrap from env vars).
- **OIDC config:** Explicit `provider.{locationUrl, authorizationUrl, tokenUrl}` (QE 0.5.3 has no auto-discovery); `client.existingSecret.name: quine-enterprise-oidc-credentials` (the K8s Secret pinned at bootstrap).
- **TLS-at-ingress (QE side):** Three JVM args required for QE's OIDC `redirect_uri` to come out as `https://...:443/...` instead of pod-local `http://...:8080/...`: `quine.webserver-advertise.{address,port,use-tls}`. Required on QE 1.10.6+.
- **Bearer-token auth:** Requires `provider.access-token-audience=quine-enterprise-client` (RFC 8725 / RFC 9068 audience binding). Without it, `Authorization: Bearer` calls return 401. The session-cookie/browser flow does NOT need this.
- **Init container chain:** `build-truststore` (creates JKS from cluster ingress CA — see below), `wait-for-cassandra` (TCP probe), `wait-for-keycloak` (TLS-validating HTTPS probe to the realm discovery endpoint).

## Cross-cutting patterns

### JVM truststore construction

QE's JVM has to trust Keycloak's TLS chain. That chain is signed by OpenShift's ingress-operator CA, which is not in the JDK's default cacerts. Prior thatDot deployments mounted a pre-built JKS from a Secret (manual setup, breaks on `crc delete` because the cluster CA regenerates).

This repo uses a three-step pipeline:

1. **`scripts/create-cluster-ingress-ca-configmap.sh`** (out-of-band, called by `bootstrap.sh`) extracts the ingress CA from `openshift-config-managed/default-ingress-cert` and creates a `cluster-ingress-ca` ConfigMap in `thatdot-openshift`. Same source as `trust-crc-ca.sh` (which lands the same CA in the macOS keychain for browser trust).

2. **`manifests/quine-enterprise/patches/build-truststore.yaml`** — init container, runs `keytool` over the ConfigMap's PEM bundle. Awk-splits the multi-cert bundle into individual files (keytool's `-importcert` only imports the first cert in a concatenated PEM, a long-standing gotcha), imports each cert into `/workspace/cacerts` (copy of the system cacerts).

3. **Main QE container** mounts the JKS via emptyDir and points the JVM at it via `-Djavax.net.ssl.trustStore=/workspace/cacerts`.

Survives `crc delete` cleanly — every bootstrap re-extracts the freshly-regenerated cluster CA; every pod start rebuilds the JKS.

The cluster ingress CA is *not* the same as the cluster Proxy CA (which `config.openshift.io/inject-trusted-cabundle: "true"` would inject); the Proxy CA bundle is for outbound traffic, not for validating Routes. Easy first-attempt mistake.

### TLS-at-ingress topology

```
Browser ──HTTPS (cluster wildcard cert)──> OpenShift router ──HTTP──> Pod
```

The pattern repeats for both Keycloak and QE. Each pod listens on plain HTTP internally; the router terminates TLS at the edge. Each consumer needs to be told what URL the *browser* sees, because each pod's view of itself is "I'm listening on HTTP port 8080" — wrong for what the browser does.

- **Keycloak side:** `hostname.hostname` = full Route URL with `https://`, `proxy.headers: xforwarded`. Without these, the OIDC discovery doc serves `http://...` URLs and JWT `iss` claims come out wrong.
- **QE side:** `quine.webserver-advertise.{address,port,use-tls=true}` (three JVM args, all required). Without them, QE generates `redirect_uri=http://...:8080/...` which Keycloak rejects because the realm only registered the `https://` form.

A second wrinkle on QE: 1.10.6 emits `:443` explicitly in the `redirect_uri` even though it's the HTTPS default port. Keycloak's path-wildcard validation is literal-string and rejects `https://host:443/*` against `https://host/*`. The realm registers **both** forms (`https://host/*` and `https://host:443/*`) in both `redirectUris` and `webOrigins` to cover the QE bug.

### Role-claim contract with QE

QE's access-token decoder (`AccessTokenClaims.decoder`) reads `roles` strictly at the JWT root:

```scala
c.downField("roles").as[Set[Role]]
```

Two non-negotiables for the realm to produce tokens QE accepts:

1. **Top-level claim.** Protocol mappers must emit roles to a top-level `roles` claim — NOT nested under `resource_access.<client>.roles` (Keycloak's default for `oidc-usermodel-client-role-mapper`), `realm_access.roles`, or a schema URI. Set `claim.name: "roles"` on every mapper. Wrong location → infinite redirect loop with `CouldNotDecodeClaim` in `/api/v2/auth/me`'s 401 body.

2. **Exact PascalCase values.** Role names must literally match the six references in `quine-auth`'s `Role` enum: `SuperAdmin`, `Admin`, `Architect`, `DataEngineer`, `Analyst`, `Billing`. The decoder does case-sensitive exact-string match with no aliasing, no case-folding, no separator normalization. `superadmin`, `super-admin`, `SUPERADMIN` are all silently discarded. Wrong values → login succeeds but every action denied (`roles: []` in `/me`'s 200 response).

Customer-facing version of this contract (with diagnostic recipes) lives at [`docs.thatdot.com/quine-enterprise/learn/oidc-setup`](https://docs.thatdot.com/quine-enterprise/learn/oidc-setup/).

## Known gaps for production

This deployment targets CRC for dev iteration. Several decisions specific to that target — or simply deferred — would need attention for a production deployment.

### Hardcoded values for the CRC apps domain

`apps-crc.testing` appears in four places:
- `manifests/keycloak/keycloak.yaml` (`hostname.hostname`)
- `manifests/keycloak/keycloak-realm-import.yaml` (`redirectUris` and `webOrigins` on `quine-enterprise-client`)
- `manifests/quine-enterprise/values.yaml` (`quine.webserver-advertise.address`)
- `manifests/quine-enterprise/patches/wait-for-keycloak.yaml` (probe URL)

A production cluster substitutes its own `apps.<cluster>.<basedomain>` everywhere. No templating mechanism is in place — these are literal strings today.

### Resource sizing

All workloads are tuned for CRC's 18GB memory envelope:

- Cassandra: 512Mi JVM heap
- Keycloak: 768Mi request / 1Gi limit
- QE: 2Gi request / 4Gi limit, `-Xmx2g`
- Postgres: ~256Mi default

Production sizing would be 5-10× across the board, depending on workload.

### Single-node Cassandra, no auth

`CassandraDatacenter.size: 1` with one PVC and no replication. Production needs 3+ nodes for RF=3 quorum, rack/AZ awareness, anti-affinity rules, TLS-in-transit, and authentication (either Cassandra's built-in `PasswordAuthenticator` or thatDot's JWT auth — the latter is implemented in [`enterprise-oauth-reference`](https://github.com/thatdot/enterprise-oauth-reference) but not ported here).

### TLS strategy

Cluster wildcard cert is fine for dev. Production might require:
- cert-manager + ACME (Let's Encrypt or internal ACME)
- Corporate CA via OpenShift's `default-ingress-cert` override
- Wildcard cert distributed via External Secrets Operator

None of those are wired here.

### Secret management

Secrets flow in via `bootstrap.sh` reading env vars and calling `oc create secret`. This is the simplest path that keeps secrets out of the public repo. Production wants something more substantial:
- Sealed Secrets (encrypt-then-commit pattern, keys held by the cluster controller)
- External Secrets Operator backed by Vault / AWS Secrets Manager / etc.
- ArgoCD Vault Plugin for sync-time substitution

Any of these would replace `bootstrap.sh`'s imperative secret-creation phase.

### Backup, monitoring, alerting

Not in scope for v1. Production needs:
- Postgres backup (continuous WAL archive, point-in-time recovery)
- Cassandra snapshots (per-node, scheduled, off-cluster storage)
- QE persistor backup strategy (depends on Cassandra backups + persistor consistency model)
- Prometheus + Grafana for metrics; AlertManager + paging for alerts

### Authentication for cluster operations

`bootstrap.sh` assumes the operator is logged in as `kubeadmin` (cluster-admin). Production uses RBAC + identity-provider-backed user accounts; `kubeadmin` is typically disabled. The bootstrap path would need to be re-shaped for a least-privilege operator role.

### Novelty and Kafka

Deliberately out of v1 scope. The `enterprise-oauth-reference` repo is the reference for adding either.
