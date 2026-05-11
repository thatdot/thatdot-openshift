# Quine Enterprise OIDC Redirect Loop — Diagnose and Fix

## Is this your problem?

If you're seeing all of these, **yes**:

- Browser shows "Redirecting to IdP…" over and over, ~once per second
- Network panel shows a tight loop: `/api/v2/auth/me` (401) → `/api/v2/auth/login` (302) → IdP `/auth?…` (302) → `/api/v2/auth/callback?…` (302) → repeat
- The 401 from `/api/v2/auth/me` has a JSON body whose `message` field contains the string `CouldNotDecodeClaim` and `.roles`
- Upgrading or downgrading QE between 1.10.x versions does not change anything

**This is not a QE version bug.** It is an Identity Provider claim-mapping bug. QE's behavior here has been the same across all 1.10.x releases. Upgrading or rolling back will not fix it — the fix is on the IdP.

## What QE requires from the JWT

QE's access-token decoder reads two things from the JWT, and both are non-negotiable:

1. A **top-level** claim named `roles` — not nested under `resource_access.<client>.roles`, not under `realm_access.roles`, not under `http://schemas.microsoft.com/.../role`, not under any other path
2. Whose values are the **exact PascalCase strings**: `SuperAdmin`, `Admin`, `Architect`, `DataEngineer`, `Analyst`, `Billing`

Any deviation produces one of two failure modes:

| What's wrong | What you see |
|---|---|
| `roles` claim is missing or at the wrong JWT path | **Infinite redirect loop.** `/me` returns 401 with message `CouldNotDecodeClaim(DecodingFailure at .roles: Missing required field)` |
| `roles` claim is present, but values are `admin` / `data-engineer` / `SUPERADMIN` / etc. | **Login succeeds, but every feature is denied.** `/me` returns 200 with `roles: []` and `permissions: []`. QE pod logs show `WARN ... Discarding unknown role name: <value>` |

The first mode is the loud one (the redirect loop). The second is the stealth one (logged in but nothing works). Customers usually hit them in that order: fix the JWT path → start seeing the second mode.

## Sample tokens — good vs bad

Decode any access token QE received by base64-decoding its middle segment:

```bash
echo '<jwt>' | cut -d. -f2 | base64 -d | jq .
```

What follows are real-shaped JWT payloads (other claims trimmed for readability), annotated to show what QE accepts and what it rejects.

### ✅ A token QE accepts

```json
{
  "iss": "https://keycloak.example.com/realms/quine-enterprise",
  "aud": ["quine-enterprise-client", "account"],
  "sub": "a76a8d54-50d4-4ff2-a38b-135d426af310",
  "azp": "quine-enterprise-client",
  "preferred_username": "superadmin1",

  "roles": ["SuperAdmin"],                ⟵ ★ what QE reads — top-level key, PascalCase value

  "realm_access": {
    "roles": ["default-roles-quine-enterprise", "offline_access"]
  },
  "resource_access": {
    "quine-enterprise-client": {
      "roles": ["SuperAdmin"]              ⟵ may also exist; QE ignores it
    }
  }
}
```

The two non-negotiable parts:

- **A key named `roles` exists at the top level** (directly under the root object, not nested anywhere).
- **Its values are from the closed set** `["SuperAdmin", "Admin", "Architect", "DataEngineer", "Analyst", "Billing"]`. Spelling is case-sensitive; values outside that set are dropped.

Everything else — `iss`, `aud`, `sub`, `realm_access`, `resource_access`, `preferred_username`, `azp`, custom claims — can be whatever your IdP emits. QE only reads four fields for authz: `iss` (issuer validation), `aud` (audience binding, only for bearer-token API access), `sub` (the subject), and `roles`.

### ❌ Bad #1: roles only nested, no top-level claim

This is the JPMC failure mode — the `CouldNotDecodeClaim` redirect loop.

```json
{
  "iss": "https://keycloak.example.com/realms/quine-enterprise",
  "aud": ["quine-enterprise-client"],
  "sub": "a76a8d54-50d4-4ff2-a38b-135d426af310",

                                            ⟵ ✗ no top-level "roles" key anywhere

  "realm_access": {
    "roles": ["default-roles-quine-enterprise"]
  },
  "resource_access": {
    "quine-enterprise-client": {
      "roles": ["SuperAdmin"]                ⟵ ✗ QE doesn't look here
    }
  }
}
```

Decoder error: `CouldNotDecodeClaim(DecodingFailure at .roles: Missing required field)`. `/api/v2/auth/me` returns **401** with that string in the response body's `message` field. The browser frontend interprets the 401 as "log the user in," redirects to IdP, comes back with a new session, hits `/me`, gets the same 401 — **infinite redirect loop**.

How to get here: Keycloak's default protocol mapper for client roles ships with `claim.name: "resource_access.${client_id}.roles"` (the nested form). Fix: change `claim.name` to the literal string `"roles"` on every protocol mapper that emits roles, for every client whose tokens QE consumes.

### ❌ Bad #2: top-level roles present but wrong-cased values

This is the stealth failure — login succeeds, nothing works.

```json
{
  "iss": "https://keycloak.example.com/realms/quine-enterprise",
  "aud": ["quine-enterprise-client"],
  "sub": "a76a8d54-50d4-4ff2-a38b-135d426af310",

  "roles": ["superadmin"]                    ⟵ ✗ wrong case — QE expects "SuperAdmin"
}
```

The decoder finds the top-level `roles` array (no `CouldNotDecodeClaim` error this time), tries to match each value against the closed set, finds no match for `"superadmin"`, logs `WARN ... Discarding unknown role name: superadmin`, drops the value. The user ends up with `Set.empty[Role]`.

`/api/v2/auth/me` returns **200** with:

```json
{
  "subject": "a76a8d54-50d4-4ff2-a38b-135d426af310",
  "roles": [],
  "permissions": []
}
```

Login succeeds. The user lands on the dashboard. Every action they try is denied (no permissions). No banner, no error — they just notice "I can't click anything." The only signal is the WARN line in QE's pod logs.

All wrong-cased variants exhibit this same behavior:

```json
{ "roles": ["admin"] }              // ✗ lowercase
{ "roles": ["ADMIN"] }              // ✗ uppercase
{ "roles": ["data-engineer"] }      // ✗ kebab-case
{ "roles": ["data_engineer"] }      // ✗ snake_case
{ "roles": ["dataEngineer"] }       // ✗ camelCase
{ "roles": ["DataEngineer"] }       // ✓ correct
```

Fix: rename roles (in the IdP) to one of the six PascalCase values, or add an IdP-side claim transformation that maps your existing role names to QE's required spelling. ADFS example is in "The fix for ADFS" below.

### ❌ Bad #3 (ADFS default): roles only under the Microsoft schema URI

This is what ADFS emits by default without any custom claim rules.

```json
{
  "iss": "https://adfs.example.com/adfs",
  "aud": ["urn:quine-enterprise"],
  "sub": "CN=Jane Doe,OU=Users,DC=example,DC=com",

                                                                       ⟵ ✗ no top-level "roles"

  "http://schemas.microsoft.com/ws/2008/06/identity/claims/role": [    ⟵ ✗ QE doesn't look here
    "QE-Admins",
    "QE-Architects"
  ]
}
```

Same decoder error as Bad #1 — top-level `roles` is missing. ADFS has its own claim-rule language for fixing this; the two-rule recipe is in "The fix for ADFS" below. Roughly: one rule pulls AD group memberships into the role claim type, a second rule re-emits each role value (or mapped value) under the literal claim name `roles`.

## Confirm it's this bug in 30 seconds

1. Open DevTools → Network panel in the looping browser tab
2. Click any failing `/api/v2/auth/me` request → **Response** tab
3. Look at the JSON body's `message` field

| `message` contains | Diagnosis |
|---|---|
| `CouldNotDecodeClaim` + `.roles` | **This bug.** Continue to "The fix for ADFS" below. |
| `Missing session cookie or access token` | Different problem — browser isn't sending the cookie. Check `Set-Cookie` attributes (`Secure`, `SameSite`, domain) on the callback response. |
| `No Session found` | QE's in-memory session cache was wiped (pod restart, etc.). Log out + back in. |
| `iss` / `aud` / `signature` keywords | Token validation failure — check IdP hostname config, audience binding, truststore. Adjacent to this bug, not the same bug. |

If you want a second confirmation: grab the access token QE received (from the failing session cookie, or by minting a token directly against the IdP) and decode it. The JWT payload is the middle base64 segment between the dots:

```bash
echo '<jwt>' | cut -d. -f2 | base64 -d | jq .
```

A broken token will be missing a top-level `roles` field. (Role values may exist under `http://schemas.microsoft.com/ws/2008/06/identity/claims/role` for ADFS, or `resource_access.<client>.roles` for Keycloak — but QE does not look at those paths.)

## The fix for ADFS

ADFS does not emit a top-level `roles` claim by default. AD group memberships land at the long Microsoft schema URI `http://schemas.microsoft.com/ws/2008/06/identity/claims/role`, which from QE's perspective is *nested* — the key contains dots and isn't `roles`.

You need a Claim Issuance Rule on the QE-as-Relying-Party trust that re-emits role values as a top-level `roles` claim. Two cases:

### Case A — your AD groups are already named exactly `SuperAdmin`, `Admin`, `Architect`, `DataEngineer`, `Analyst`, `Billing`

Add two rules:

```
# Rule 1: Pull AD group memberships into the standard role claim type.
c:[Type == "http://schemas.microsoft.com/ws/2008/06/identity/claims/windowsaccountname",
   Issuer == "AD AUTHORITY"]
 => issue(store = "Active Directory",
          types = ("http://schemas.microsoft.com/ws/2008/06/identity/claims/role"),
          query = ";tokenGroups;{0}",
          param = c.Value);

# Rule 2: Re-emit those role values as a top-level "roles" claim that QE reads.
c:[Type == "http://schemas.microsoft.com/ws/2008/06/identity/claims/role"]
 => issue(Type = "roles", Value = c.Value);
```

### Case B — your AD groups have a different naming convention (e.g. `QE-Admins`, `QE-Data-Engineers`)

Replace Rule 2 with one explicit-mapping rule per role:

```
# Rule 1: Same as above — pull AD group memberships into the role claim type.
c:[Type == "http://schemas.microsoft.com/ws/2008/06/identity/claims/windowsaccountname",
   Issuer == "AD AUTHORITY"]
 => issue(store = "Active Directory",
          types = ("http://schemas.microsoft.com/ws/2008/06/identity/claims/role"),
          query = ";tokenGroups;{0}",
          param = c.Value);

# Rules 2..N: Map each AD group to a QE role. Repeat per role you want to grant.
c:[Type == "http://schemas.microsoft.com/ws/2008/06/identity/claims/role", Value == "QE-Super-Admins"]
 => issue(Type = "roles", Value = "SuperAdmin");

c:[Type == "http://schemas.microsoft.com/ws/2008/06/identity/claims/role", Value == "QE-Admins"]
 => issue(Type = "roles", Value = "Admin");

c:[Type == "http://schemas.microsoft.com/ws/2008/06/identity/claims/role", Value == "QE-Architects"]
 => issue(Type = "roles", Value = "Architect");

c:[Type == "http://schemas.microsoft.com/ws/2008/06/identity/claims/role", Value == "QE-Data-Engineers"]
 => issue(Type = "roles", Value = "DataEngineer");

c:[Type == "http://schemas.microsoft.com/ws/2008/06/identity/claims/role", Value == "QE-Analysts"]
 => issue(Type = "roles", Value = "Analyst");

c:[Type == "http://schemas.microsoft.com/ws/2008/06/identity/claims/role", Value == "QE-Billing"]
 => issue(Type = "roles", Value = "Billing");
```

Don't keep both Rule 2 styles — pick one. Case A passes raw AD group names through; Case B replaces them with QE's exact role names. Mixing the two produces a `roles` claim with both originals and translations, which works but is messy.

## Verify the fix

1. **Mint a fresh token.** Restart the user's browser session (close tab, clear cookies for the QE domain, log in again) so the IdP issues a new JWT — old tokens were minted under the old rules and stay broken until they expire.

2. **Decode the access token** (from DevTools Application → Cookies → look at the QE session cookie, or capture it from the network panel during login):

   ```bash
   echo '<jwt>' | cut -d. -f2 | base64 -d | jq '{iss, sub, aud, roles}'
   ```

   Expected: top-level `roles` field, populated with one or more of `SuperAdmin`, `Admin`, `Architect`, `DataEngineer`, `Analyst`, `Billing`.

3. **Hit `/api/v2/auth/me`** with that token:

   ```bash
   curl -H "Authorization: Bearer <jwt>" https://<qe-host>/api/v2/auth/me
   ```

   Expected: 200 OK, with `roles` matching what's in the JWT, and a non-empty `permissions` array (1 permission for `Billing`, up to 34 for `SuperAdmin`).

If the JWT has top-level `roles` but `/me` returns empty `roles: []`, you're in the second failure mode — your AD group values are reaching QE but don't match the required PascalCase spelling. Switch to Case B mappings above, or rename the AD groups to match exactly.

## After the fix is deployed

Existing user sessions are cached server-side with the *old* broken access tokens. They'll keep looping until either:

- Each user explicitly logs out and logs back in (forces a fresh token), or
- QE is restarted, which wipes the in-memory session cache for everyone at once

For self-managed deployments, restart QE the way you normally would. The IdP fix without one of these two follow-ups will look like "the fix didn't work" to anyone who had an open session.

## Why this presents as "the page just keeps reloading"

QE's frontend has only one "unauthenticated" path: any 401 from `/api/v2/auth/me` triggers an immediate redirect to `/api/v2/auth/login`. It does not distinguish between "no session, please log in" (a legitimate redirect) and "session present but the token in it is structurally invalid" (a configuration error that login will never fix).

When the token is structurally invalid, the user goes through the full auth-code flow at the IdP, comes back to QE with a new session cookie that contains the same kind of broken token, hits `/me`, gets the same decode error, gets redirected again — a tight loop with no exit. The user sees a "Redirecting to IdP…" page that refreshes about once per second. There is no error message in the UI.

This UX behavior is a known product gap and is being tracked separately from this configuration bug. For now, the only signal that distinguishes "real auth needed" from "config error" is the JSON body of the `/me` 401 response — which is why the diagnosis above leads with that.

## Appendix: the same bug in Keycloak

For internal reference, the Keycloak-side equivalent is a missing or misconfigured protocol mapper on the QE client.

Required mapper on every client whose tokens QE consumes (interactive client + service-account clients):

- **Mapper type:** `oidc-usermodel-client-role-mapper`
- **`claim.name`:** the literal string `roles` — **not** `resource_access.${client_id}.roles`, **not** any other nested path
- **`usermodel.clientRoleMapping.clientId`:** the QE client ID

Role names defined in the realm and assigned in `clientRoles:` blocks must be the exact PascalCase strings (`SuperAdmin`, `Admin`, etc.).

Note: `KeycloakRealmImport` is create-only. If you edit the realm-import YAML to fix this, the operator will not re-import. To force a re-import, delete the realm in Keycloak first (`kcadm.sh delete realms/<name>`), then delete + recreate the `KeycloakRealmImport` CR. Re-importing also regenerates the client secret, so the application Secret holding it must be re-extracted and the application restarted.
