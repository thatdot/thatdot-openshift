#!/usr/bin/env bash
set -euo pipefail

# Creates the `quine-enterprise-oidc-credentials` Secret in the thatdot-openshift
# namespace. Carries the OIDC client_id + client_secret for QE's auth against
# the `quine-enterprise` Keycloak realm.
#
# Why out-of-band:
#   The client_secret for `quine-enterprise-client` is operator-generated when
#   Keycloak imports the realm (we deliberately omit `secret:` from the realm
#   YAML — see "Public-repo safe" in IMPLEMENTATION_PLAN.md step 5). There's
#   no GitOps-pure way to read the value back out, so this script polls
#   Keycloak via kcadm.sh and creates the K8s Secret directly.
#
# Idempotency:
#   - If the Secret already exists, no-op. Re-running bootstrap.sh after the
#     initial deploy doesn't fight with the (already-correct) Secret. This
#     also means: if Keycloak rotates the client secret in admin UI, our
#     K8s Secret won't auto-update. To force a re-fetch:
#       oc delete secret quine-enterprise-oidc-credentials -n thatdot-openshift
#     then re-run the script.
#
# Prerequisites (caller must ensure):
#   - The thatdot-openshift namespace exists
#   - The Keycloak pod is Running AND the `quine-enterprise` realm is imported
#     (bootstrap.sh waits for both before invoking this script)
#
# Usage: ./scripts/create-qe-oidc-client-secret.sh

NAMESPACE="thatdot-openshift"
SECRET_NAME="quine-enterprise-oidc-credentials"
CLIENT_ID="quine-enterprise-client"
REALM="quine-enterprise"

if oc get secret "$SECRET_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
    echo "Secret '$SECRET_NAME' already exists — leaving it alone."
    exit 0
fi

# Locate the Keycloak pod (the operator creates a StatefulSet named keycloak-0)
KC_POD=$(oc get pod -n "$NAMESPACE" -l app=keycloak -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [[ -z "$KC_POD" ]]; then
    echo "ERROR: no Keycloak pod found in namespace $NAMESPACE (label app=keycloak)."
    echo "       Is the Keycloak stack deployed and Ready?"
    exit 1
fi

# Pull the admin creds from the operator-generated Secret. RHBK 26.4 names the
# initial admin `temp-admin`, not `admin` — always read both keys.
ADMIN_USER=$(oc get secret keycloak-initial-admin -n "$NAMESPACE" -o jsonpath='{.data.username}' | base64 -d)
ADMIN_PW=$(oc get secret keycloak-initial-admin -n "$NAMESPACE" -o jsonpath='{.data.password}' | base64 -d)

# Run kcadm inside the Keycloak pod. Pass the admin password via env (not
# shell-interpolated) so special characters don't break the call. Use exact
# username match (-q exact=true) — kcadm's default partial match silently
# returns wrong users when one username is a substring of another (see CLAUDE.md
# kcadm gotcha).
echo "Retrieving client secret for '$CLIENT_ID' in realm '$REALM' from Keycloak..."
CLIENT_SECRET=$(oc exec -n "$NAMESPACE" "$KC_POD" -- env ADMIN_PW="$ADMIN_PW" /bin/bash -c "
    set -euo pipefail
    /opt/keycloak/bin/kcadm.sh config credentials \
        --server http://localhost:8080 --realm master \
        --user $ADMIN_USER --password \"\$ADMIN_PW\" >/dev/null
    CID=\$(/opt/keycloak/bin/kcadm.sh get clients -r $REALM -q exact=true -q clientId=$CLIENT_ID \
        --fields id --format csv --noquotes | tail -1 | tr -d '\r')
    if [[ -z \"\$CID\" ]]; then
        echo \"ERROR: client '$CLIENT_ID' not found in realm '$REALM'\" >&2
        exit 1
    fi
    /opt/keycloak/bin/kcadm.sh get \"clients/\$CID/client-secret\" -r $REALM \
        --fields value --format csv --noquotes | tail -1 | tr -d '\r'
")

if [[ -z "$CLIENT_SECRET" ]]; then
    echo "ERROR: empty client secret returned from kcadm."
    exit 1
fi

# Create the K8s Secret. We provide multiple key-name variants
# (clientId/clientSecret, client-id/client-secret) so the QE chart finds its
# expected names regardless of which convention it follows — cheaper than
# hunting down chart source.
oc create secret generic "$SECRET_NAME" \
    --from-literal=clientId="$CLIENT_ID" \
    --from-literal=clientSecret="$CLIENT_SECRET" \
    --from-literal=client-id="$CLIENT_ID" \
    --from-literal=client-secret="$CLIENT_SECRET" \
    -n "$NAMESPACE"

echo "Secret '$SECRET_NAME' created in namespace $NAMESPACE."
echo "  clientId:     $CLIENT_ID"
echo "  clientSecret: <retrieved from Keycloak, not echoed>"
