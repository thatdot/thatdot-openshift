# Quine Enterprise OIDC Redirect Loop — Root Cause Analysis

## TL;DR

**The redirect loop happens when the JWT access token Keycloak gives QE does not contain a top-level `roles` claim.** QE's `AccessTokenClaims.decoder` reads `roles` strictly at the JWT root with no fallback paths and no configurable claim location. If the claim is missing (or only present at a nested path like `resource_access.<client>.roles`), the decoder returns `CouldNotDecodeClaim(DecodingFailure at .roles: Missing required field)`, `/api/v2/auth/me` returns 401, and the browser's `AuthenticationWrapper` immediately redirects to `/api/v2/auth/login`. Keycloak auto-approves the still-active session, redirects back, callback succeeds, new session cookie is set, `/me` is called again, same decode error, same redirect — an infinite tight loop.

**The fix is in the Keycloak realm**, not in QE. The `oidc-usermodel-client-role-mapper` on every confidential client that QE consumes (interactive client + any service-account clients) must have `claim.name: "roles"` (top-level), NOT `claim.name: "resource_access.${client_id}.roles"` (nested, which is sometimes Keycloak's default) and not any other nested form.

**The team has only observed this loop with TLS termination enabled, but that correlation is from confounded variables, not causation.** Two test deployments without TLS termination (`thatdot-auth-services`, `opstools/keycloak`) shipped with correct realm configs and never exercised the bug. The TLS-terminated deployment (`thatdot-openshift`) was where the realm was authored fresh, and that's where the incorrect `claim.name` was introduced. Empirical proof in the *other* direction: with TLS termination still enabled and only `claim.name` corrected to `"roles"`, password-grant tokens against the realm now contain top-level `roles: ["admin"]` (verified by JWT decode). So the fix works under TLS termination, which is incompatible with TLS-termination being causal. See "The TLS-termination correlation" section for full analysis.

## Symptom

User clicks "Log in" or navigates to QE's protected URL. They observe:

- Browser navigates from QE → Keycloak login form → (briefly) QE → Keycloak → QE → … rapidly, ~once per second
- No visible error message in the UI; the page shows "Redirecting to IdP…" spinner
- Network panel shows alternating `me` (401) → `login` (302) → Keycloak's `auth?...` (302) → `callback?...` (302) requests, looping indefinitely
- Browser DevTools console may show `Authentication failed: Error <Circe DecodingFailure>` from the `AuthenticationWrapper`

The loop never resolves — it persists until the browser tab is closed.

## Where the bug actually lives

### QE's claim decoder (the strict consumer)

In `quine-auth/src/main/scala/com/thatdot/quine/auth/AccessTokenClaims.scala`:

```scala
implicit def decoder[P <: Permission](implicit roleDecoder: Decoder[Option[Role[P]]]): Decoder[AccessTokenClaims[P]] =
  (c: HCursor) =>
    for {
      iss <- c.downField("iss").as[Issuer]
      aud <- c.downField("aud").as[NonEmptySet[Audience]]
      sub <- c.downField("sub").as[String]
      roles <- c.downField("roles").as[Set[Option[Role[P]]]]   // ← reads top-level `roles`
    } yield AccessTokenClaims(...)
```

This decoder reads `roles` as a **top-level** JWT claim. It will fail with `DecodingFailure at .roles: Missing required field` if:
- The `roles` claim is absent from the JWT
- The `roles` claim is nested anywhere else (`resource_access.<client>.roles`, `realm_access.roles`, etc.)

QE makes no attempt to find roles elsewhere. There is no fallback path. The claim location is not configurable.

### Keycloak's protocol mapper (the source of the JWT)

In Keycloak, client roles are placed into JWTs by a protocol mapper named (by convention) `roles`, typically of type `oidc-usermodel-client-role-mapper`. The mapper's `claim.name` field controls **the exact JWT path where the claim lands**. Common configurations:

| `claim.name` | JWT shape | Compatible with QE? |
|---|---|---|
| `"roles"` | `{"roles": ["admin"], ...}` | ✅ Yes — top-level |
| `"resource_access.${client_id}.roles"` | `{"resource_access": {"my-client": {"roles": ["admin"]}}, ...}` | ❌ No — nested |
| `"realm_access.roles"` | `{"realm_access": {"roles": ["admin"]}}` | ❌ No — nested |

The correct value for QE is **`claim.name: "roles"`**.

### Why this trips integrators up

Keycloak has a *separate* built-in client scope, also confusingly named `roles`, that adds its own protocol mappers which place roles at `realm_access.roles` and `resource_access.<client>.roles`. When you assign that built-in scope to your client, those nested locations get populated **automatically** — and looking at a working Keycloak realm export, you can see `roles` data at those nested paths. The integrator naturally thinks "ah, that's where roles go" and writes `claim.name: "resource_access.${client_id}.roles"`.

But QE's decoder doesn't look there. QE specifically looks at the JWT root.

So you have to add a **custom** mapper (the `roles` mapper at the *client* level, separate from the built-in scope) with `claim.name: "roles"` to put a copy of the roles at the top level.

## Why the bug presents as a "redirect loop"

QE's frontend (`quine-enterprise-browser/.../AuthenticationWrapper.scala`) handles unauthenticated state by *immediately* redirecting to login:

```scala
case Unauthenticated(error) =>
  dom.console.error(s"Authentication failed: $error")
  redirectToLogin()
  renderLoading()
```

There is **only one unauthenticated state** in the wrapper. Any 401 from `/api/v2/auth/me` triggers `redirectToLogin()`. The wrapper does not distinguish between:

1. "No session cookie" → user genuinely needs to log in (legitimate redirect)
2. "Session cookie is expired" → user needs to refresh login (legitimate redirect)
3. **"Session cookie is valid but the JWT in it can't be decoded" → configuration error; login will never fix it (BAD redirect)**

For case 3, the user goes through Keycloak's auth code flow, gets back to QE, QE caches a session, then immediately fails to validate that session for the same reason it failed before. Tight loop.

If `AuthenticationWrapper` rendered an error page for `CouldNotDecodeClaim` errors instead of redirecting, the integration error would be visible to humans in <10 seconds and the redirect loop would not exist. The looping behavior is a UX bug on top of a configuration error.

## The TLS-termination correlation: real but coincidental

Empirically, this team's experience has been that **the redirect loop only occurs with TLS termination at the ingress**. Disable TLS termination (e.g., use a non-edge-terminated route, or talk to QE directly over HTTPS-at-the-pod or plain HTTP) and the loop goes away. This is a strong observation that deserves a careful explanation rather than dismissal.

The most likely explanation — supported by side-by-side comparison of the realm configs across the working and broken deployments — is that **the test configurations confound two variables**:

| Deployment tested | TLS at ingress? | `claim.name` for QE's role mapper | Outcome |
|---|---|---|---|
| `thatdot-auth-services` (`enterprise-oauth-reference`) | ❌ no | `roles` (top-level) ✓ | works |
| `opstools/keycloak` | ❌ no | `roles` (top-level) ✓ | works |
| `thatdot-openshift` (this repo, before the fix) | ✅ yes | `resource_access.${client_id}.roles` (nested) ✗ | **loops** |

The two non-TLS deployments inherited correct realm configs from prior art and never exercised the bad path. The TLS-terminated deployment was where the realm was authored fresh for OpenShift — and that's where the `claim.name` was set incorrectly. So in this team's experience, the loop has only been seen *while* TLS termination was enabled, but that's because **TLS termination and "fresh realm config" were varied together, not because TLS termination causes the loop**.

Direct evidence from the troubleshooting session: with our deployment still TLS-terminated, after correcting only `claim.name` to `roles`, a password-grant against `quine-enterprise-client` produces a token with `roles: ["admin"]` at the top level — verified by decoding the JWT payload. The fix worked under TLS termination, which it could not have if TLS termination were causal.

Two TLS-termination-related issues sit *adjacent* to this bug and can confuse the picture by masking it on the first try:

| Layer | Failure | Symptom | Fix |
|---|---|---|---|
| 1 | Keycloak emits tokens with `iss` claim using the wrong scheme (`http://` because Keycloak's pod sees plain HTTP behind the proxy) | QE's OIDC validation rejects all tokens — "issuer mismatch" | Set `Keycloak.spec.hostname.hostname` to the public URL with `https://`; `proxy.headers: xforwarded` |
| 2 | QE emits `redirect_uri=http://...` in the auth-code request (QE sees plain HTTP locally) | Keycloak rejects redirect — "Invalid redirect_uri" | QE 1.10.6+: set `quine.webserver-advertise.use-tls=true` + matching `.address` and `.port`; register both `https://host/*` and `https://host:443/*` in Keycloak's realm |
| 3 | Roles claim in wrong JWT location | `CouldNotDecodeClaim` → redirect loop | **This document's topic** — `claim.name: "roles"` |

Layers 1 and 2 *are* genuinely TLS-termination concerns: they're about URL scheme correctness across the proxy boundary. **Layer 3 has nothing to do with TLS.** The reason it presents as "TLS-correlated" in this team's experience: layers 1 and 2 must be fixed before layer 3 ever surfaces (you can't log in to *get* a token with the wrong shape until the redirect URLs work), so layer 3 is always observed in the context of TLS-aware deployments where 1 and 2 have just been fixed.

A definitive disambiguating test would be: deploy this repo's realm config (with `claim.name: "resource_access.${client_id}.roles"`) into a non-TLS-terminated environment. The loop will reproduce on first login. That experiment hasn't been run, but the password-grant evidence above demonstrates the same point from the other direction — the TLS-terminated deployment works fine once the realm is fixed.

A new integrator who follows Keycloak's default-mapper conventions and looks at JWT output from Keycloak's admin UI (which prominently shows roles under `resource_access.<client>.roles`) is naturally led to the wrong configuration. **The loop is the first signal something is wrong, and that signal is uninformative.** That's the actual product gap: not "TLS doesn't work" but "QE's UX makes a configuration mistake feel like a deployment-topology issue."

## Diagnostic procedure

If you're hit by the loop, this is the **30-second diagnosis**:

1. Open DevTools → Network panel
2. Click any `me` request → Response tab
3. Inspect the JSON body — look at the `message` field of the error

| `message` value | What's wrong | Where to fix |
|---|---|---|
| `"Missing session cookie or access token."` | Browser isn't sending the cookie (network/proxy issue) | Check cookie attributes on the callback's Set-Cookie response |
| `"<jwt decode err>"` (anything that mentions JWT signature) | Session-signing secret rotated | QE pod restarted; re-login |
| `"No Session found."` | Cache miss on `sessionCache.retrieveSession` | QE in-memory session cache wiped (restart) or Pekko cluster issue; re-login |
| **`"CouldNotDecodeClaim(DecodingFailure at .roles: Missing required field)"`** | **JWT roles claim missing or nested** | **Fix Keycloak realm mapper: `claim.name: "roles"`** |
| `<oidc4s error>` mentioning signature / issuer / audience | Access token validation failure (less common) | Check Keycloak hostname config, truststore, audience binding |
| `"Bearer-token authentication is not configured..."` | Wrong code path | Check `provider.access-token-audience` config on QE |

If the message contains "CouldNotDecodeClaim" and ".roles", **this document's problem is yours**, and the fix is in the next section.

## The fix

In Keycloak (admin UI or realm-import YAML), find every client that QE will receive tokens from — that's both the **interactive client** (browser auth code flow) and any **service-account clients** (machine-to-machine `client_credentials` flow) — and configure each one's `roles` protocol mapper as follows:

**Mapper type:** `oidc-usermodel-client-role-mapper`

**Required config:**
```
claim.name:                              roles
jsonType.label:                          String
multivalued:                             true
access.token.claim:                      true
id.token.claim:                          true
userinfo.token.claim:                    true
usermodel.clientRoleMapping.clientId:    <your client id>
```

**Most important:** `claim.name` must be the exact literal string `roles`. Not `resource_access.${client_id}.roles`, not `realm_access.roles`, not any other nested path.

In a `KeycloakRealmImport` YAML (Keycloak Operator), it looks like:

```yaml
protocolMappers:
  - name: roles
    protocol: openid-connect
    protocolMapper: oidc-usermodel-client-role-mapper
    consentRequired: false
    config:
      claim.name: "roles"
      jsonType.label: String
      multivalued: "true"
      userinfo.token.claim: "true"
      id.token.claim: "true"
      access.token.claim: "true"
      usermodel.clientRoleMapping.clientId: quine-enterprise-client
```

Make sure this mapper is added to **every** client that issues tokens QE will consume. In a typical deployment that's at least the interactive `quine-enterprise-client` and possibly N service-account clients.

After fixing the realm:

1. **Existing user sessions are cached with the broken access token.** QE keeps the access token in an in-memory `sessionCache`. Existing sessions will continue to fail until the cached token is invalidated. Either restart QE (`oc rollout restart deployment quine-enterprise` for an OpenShift deploy) to wipe the cache, or have users explicitly Logout and re-login.

2. **In Keycloak: if you used a `KeycloakRealmImport` CR to import the realm, the re-import will *not* happen automatically when you edit the YAML.** The operator's import strategy is `IGNORE_EXISTING`, not `OVERWRITE_EXISTING`. To force the re-import, you must delete the realm in Keycloak first (`kcadm.sh delete realms/<name>`) and then delete + recreate the `KeycloakRealmImport` CR. The fresh CR will find the realm absent and import cleanly.

3. **Re-importing the realm regenerates client secrets.** Any OIDC client whose `secret:` field was left unset in the realm import (so Keycloak generated one) will get a fresh secret. Any K8s Secret your application uses to authenticate to Keycloak must be updated with the new value. For thatdot-openshift specifically, see `scripts/create-qe-oidc-client-secret.sh`.

## Verification

After the fix, mint an access token via password grant (or look at one in the browser session) and decode the JWT payload (the middle base64 segment). The decoded JSON should contain a top-level `roles` array:

```json
{
  "iss": "https://your-keycloak/realms/your-realm",
  "aud": "your-client-id",
  "sub": "...",
  "roles": ["admin"],         ← MUST exist at the top level
  "resource_access": {
    "your-client-id": {
      "roles": ["admin"]      ← may also be present; QE ignores this path
    }
  },
  ...
}
```

If `roles` is at the top level, `/api/v2/auth/me` will return 200 with the user's roles populated, and the redirect loop will not occur.

## A related bug: role *names* that don't match QE's expected references

After fixing `claim.name` so the JWT carries `roles: [...]` at the top level, you may still observe **"logged in but `/me` returns empty `roles` and `permissions`"**. This is a *different* realm-config bug that's commonly hit in the same session as the claim-location one, but it presents differently — there is no redirect loop, because `AccessTokenClaims.decoder` succeeds. The `roles` claim is structurally valid; the *values* inside it just aren't recognized.

### Where this bug lives

In `quine-auth/src/main/scala/com/thatdot/quine/auth/Role.scala`:

```scala
def fromReferenceOrName(s: String): Option[Role[P]] = s match {
  case Role.Admin.reference        | Role.Admin.name        => Some(admin)
  case Role.Analyst.reference      | Role.Analyst.name      => Some(analyst)
  case Role.Architect.reference    | Role.Architect.name    => Some(architect)
  case Role.Billing.reference      | Role.Billing.name      => Some(billing)
  case Role.DataEngineer.reference | Role.DataEngineer.name => Some(dataEngineer)
  case Role.SuperAdmin.reference   | Role.SuperAdmin.name   => Some(superAdmin)
  case _ =>
    logger.warn(safe"Discarding unknown role name: ${Safe(s)}")
    None
}
```

The role reference strings are **PascalCase, exact-match**: `Admin`, `Analyst`, `Architect`, `Billing`, `DataEngineer`, `SuperAdmin`. There is no case-folding, no aliasing, no namespacing, no separator normalization. `superadmin`, `super-admin`, `super_admin`, `SUPERADMIN`, or any other variant will be silently discarded and an `Option.flatten` will then drop it from the resulting `Set[Role[P]]`. The user authenticates successfully but ends up with `roles: []`.

### How to spot it

QE pod logs will contain WARN lines (one per unrecognized role value, per token verification):

```
WARN [NotFromActor] com.thatdot.quine.auth.Role$ - Discarding unknown role name: superadmin
```

Decoding the JWT payload will show roles claim populated but with wrong-cased values:

```json
{
  "roles": ["superadmin"],   ← claim is there, but value is wrong case
  ...
}
```

`/api/v2/auth/me` returns 200 with:

```json
{
  "subject": "...",
  "roles": [],          ← empty — values were discarded
  "permissions": []     ← empty — no roles, no permissions
}
```

### The fix

In your Keycloak realm, the **role names** assigned to clients (and the names referenced in `clientRoles:` user assignments) must be the exact strings:

| Role | Required exact spelling |
|---|---|
| Super Admin | `SuperAdmin` |
| Admin | `Admin` |
| Architect | `Architect` |
| Data Engineer | `DataEngineer` |
| Analyst | `Analyst` |
| Billing | `Billing` |

In a `KeycloakRealmImport`:

```yaml
roles:
  client:
    quine-enterprise-client:
      - name: SuperAdmin       # ← PascalCase, no spaces, exact
        description: Full administrative access
      - name: DataEngineer     # ← Pascal-cased compound; not "data-engineer", not "dataengineer"
        description: Ingest pipelines + standing queries
      # ...

users:
  - username: superadmin1
    clientRoles:
      quine-enterprise-client:
        - SuperAdmin           # ← matches role definition above; case matters
```

### Why this trips integrators up

Three reasons:

1. **Identity providers normalize differently.** Some IdPs (Azure AD groups, AD via ADFS) emit role names exactly as administrators typed them in the directory. Others (Auth0 rules, some Keycloak setups) lowercase or namespace them by convention. There's no industry-standard convention for the *spelling* of role names — only that they're strings.
2. **The failure mode is silent.** No 401, no redirect loop, no banner — just an empty roles array. A user who logs in successfully and lands on the dashboard will typically not notice the missing roles until they try to use a feature that's gated by a permission.
3. **Keycloak's UI is permissive.** You can name a client role `data-engineer` or `dataEngineer` or `DATA_ENGINEER`; Keycloak doesn't care. QE does. This is a hidden contract between QE and the realm config that isn't surfaced anywhere.

### Why QE's design here is also a UX problem

The decoder logs a WARN when it discards an unknown role and otherwise carries on. There's no signal to the *user* — and arguably no signal to an *operator* either, unless they happen to be tailing QE's logs at the moment of an auth attempt. A better design would either:

- Return an explicit `Unauthorized` (or `Forbidden`) when the role claim contains values but none are recognized — making the misconfiguration impossible to ignore; **or**
- Surface a configurable mapping table (`quine.auth.role-aliases.superadmin = SuperAdmin`) so the integrator can map their IdP's spelling to QE's references without changing the IdP — which is often easier than mutating an enterprise directory.

### Relationship to the redirect loop

| Bug | JWT shape | Decoder result | UX outcome |
|---|---|---|---|
| `claim.name` nested | `{ resource_access: { client: { roles: [...] } } }` (no top-level `roles`) | `CouldNotDecodeClaim(.roles: Missing required field)` | **Infinite redirect loop** (this document's main topic) |
| Role names wrong case | `{ roles: ["superadmin"], ... }` | `claims.roles = Set()` (silently empty) | **Logged in, but every permission check denied** |

Both bugs are *realm-config* errors and both produce broken authorization, but they manifest in opposite ways: one as a denial-of-service loop that's loud and obvious, the other as a stealth "all features disabled" that's quiet and easy to miss.

## What the QE product should do differently (recommendations)

The root cause is a customer configuration error, but the *user experience* of the failure is genuinely broken. Three product changes would meaningfully improve this:

### 1. Frontend should not loop on configuration errors

In `quine-enterprise-browser/.../AuthenticationWrapper.scala`, the `Unauthenticated` case should distinguish "no session" (legitimate redirect to login) from "session present but server returned a structural error" (do not redirect; render an error page). The 401 response body's `message` field is sufficient — when it contains `CouldNotDecodeClaim` or any other "the configuration is wrong" indicator, the wrapper should show:

> *"Authentication is misconfigured. Your identity provider is not emitting the expected token shape. Contact your administrator. (Technical detail: [error message])"*

This change alone would have reduced the debugging time from hours to seconds in every case I've seen.

### 2. Backend should accept multiple known role-claim locations

`AccessTokenClaims.decoder` currently hardcodes `c.downField("roles")`. A more accommodating decoder would try multiple known paths in order, falling back through:

1. Top-level `roles` (Azure AD, Auth0 default, etc.)
2. `realm_access.roles` (Keycloak realm roles)
3. `resource_access.<client>.roles` (Keycloak client roles)

Even better: make the claim path **configurable** via QE config:

```
quine.auth.oidc.full.provider.claims-paths.roles = "resource_access.quine-enterprise-client.roles"
```

This is the convention other JWT libraries use (Spring Security's `JwtAuthenticationConverter`, Auth0's middleware, etc.). It lets the IdP keep its native claim layout and lets QE adapt — which is the right ergonomics for a product that integrates with many IdPs.

### 3. Documentation should include the explicit contract

There should be an "Integrating with Keycloak" doc (and equivalents for ADFS, Azure AD, Auth0, Okta) that says, in the second paragraph:

> *"QE reads roles from the JWT's top-level `roles` claim. For Keycloak, configure your client's protocol mappers with a mapper of type `oidc-usermodel-client-role-mapper` and `claim.name: \"roles\"`. Do not use the default Keycloak nested location."*

Plus a sample realm export that customers can adapt.

The two reference deployments in `thatdot-auth-services` and `opstools/keycloak` both have correct configs — they could be the basis for the published reference.

## Appendix: ADFS configuration

For customers using ADFS (which is common in enterprise environments), the equivalent configuration is a custom Claim Issuance Rule on the QE-as-Relying-Party trust. By default, ADFS emits AD group memberships under the long Microsoft schema URI `http://schemas.microsoft.com/ws/2008/06/identity/claims/role`. QE needs them as a top-level `roles` claim.

Two ADFS claim rules accomplish this:

```
# Rule 1: pull AD group memberships into the standard role claim type
c:[Type == "http://schemas.microsoft.com/ws/2008/06/identity/claims/windowsaccountname",
   Issuer == "AD AUTHORITY"]
 => issue(store = "Active Directory",
          types = ("http://schemas.microsoft.com/ws/2008/06/identity/claims/role"),
          query = ";tokenGroups;{0}",
          param = c.Value);

# Rule 2: transform to a top-level "roles" claim type that QE expects
c:[Type == "http://schemas.microsoft.com/ws/2008/06/identity/claims/role"]
 => issue(Type = "roles", Value = c.Value);
```

Same end result: the JWT (or SAML assertion converted to JWT, depending on flow) carries a top-level `roles` claim populated with the user's AD group memberships. The QE-side role names must match what your AD provides (or you add a third claim rule that maps AD group names to QE role names).
