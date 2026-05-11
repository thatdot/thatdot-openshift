#!/usr/bin/env bash
set -euo pipefail

# Creates the `quine-enterprise-oidc-credentials` Secret in the thatdot-openshift
# namespace. Carries the OIDC client_id + client_secret for QE's auth against
# the `quine-enterprise` Keycloak realm.
#
# Pinned-secret pattern (replaces the prior extract-from-Keycloak approach):
#   The K8s Secret is created here with a freshly-generated random client_secret.
#   The `post-sync-pin-client-secret` ArgoCD hook then uses kcadm.sh to push
#   this same value INTO Keycloak (overwriting whatever the operator
#   auto-generated during realm import). Result: realm re-imports no longer
#   rotate the client_secret, so QE keeps serving across realm-config changes
#   without restart.
#
# Why pinned-not-extracted:
#   KeycloakRealmImport is permanently create-only (Keycloak Operator design,
#   not just RHBK — verified upstream as of 2026). To apply realm changes via
#   GitOps, the realm has to be deleted + re-created, which rotates the
#   auto-generated client_secret. Extracting after each rotation cascaded into
#   QE Secret + QE rollout — a 1-2 min outage per iteration. Pinning the secret
#   in K8s and pushing it into Keycloak instead inverts the dependency: the K8s
#   Secret is the source of truth, and Keycloak is reconciled to match.
#
# Idempotency:
#   - First run: generates a fresh random client_secret, creates the Secret.
#   - Subsequent runs: preserves the existing client_secret (so realm re-imports
#     continue to pin the same value). No-op.
#
# Public-repo safe: the client_secret never lives in git — only in the cluster
# Secret. Generated locally via openssl rand.
#
# Requires:
#   - The thatdot-openshift namespace to exist
#   - `oc` authenticated as a user that can read/create Secrets there
#
# Usage: ./scripts/create-qe-oidc-credentials-secret.sh

NAMESPACE="thatdot-openshift"
SECRET_NAME="quine-enterprise-oidc-credentials"
CLIENT_ID="quine-enterprise-client"

if oc get secret "$SECRET_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
    echo "Secret '$SECRET_NAME' already exists — leaving it alone."
    echo "  (To force-rotate: oc delete secret $SECRET_NAME -n $NAMESPACE, then re-run)"
    exit 0
fi

# 32 random base64 chars, stripped of '/' '+' '=' so the secret survives any
# URL/form-encoding pipelines downstream without escaping tricks. ~190 bits of
# entropy after stripping.
CLIENT_SECRET=$(openssl rand -base64 48 | tr -d '/+=' | head -c 32)

# Multiple key-name variants (clientId/clientSecret, client-id/client-secret) so
# both the post-sync pin hook and the QE Helm chart find the keys regardless of
# which convention each expects. Cheaper than auditing every consumer.
oc create secret generic "$SECRET_NAME" \
    --from-literal=clientId="$CLIENT_ID" \
    --from-literal=clientSecret="$CLIENT_SECRET" \
    --from-literal=client-id="$CLIENT_ID" \
    --from-literal=client-secret="$CLIENT_SECRET" \
    -n "$NAMESPACE"

echo "Secret '$SECRET_NAME' created in namespace $NAMESPACE."
echo "  clientId:     $CLIENT_ID"
echo "  clientSecret: <32-char random string, not echoed>"
