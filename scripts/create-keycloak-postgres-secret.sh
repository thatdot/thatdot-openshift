#!/usr/bin/env bash
set -euo pipefail

# Creates the `keycloak-postgres-app` Secret in the thatdot-openshift namespace.
# Holds DB credentials shared between:
#   - the Postgres Deployment (POSTGRESQL_USER + POSTGRESQL_PASSWORD on first boot)
#   - the Keycloak CR (db.usernameSecret + db.passwordSecret)
#
# Idempotent:
#   - First run: generates a fresh random password, creates the Secret.
#   - Subsequent runs: preserves the existing password (so the Postgres pod's
#     persisted state matches what Keycloak knows). No-op.
#
# Public-repo safe: the password never lives in git — only in the cluster Secret.
#
# Requires:
#   - The thatdot-openshift namespace to exist
#   - `oc` authenticated as a user that can read/create Secrets there
#
# Usage: ./scripts/create-keycloak-postgres-secret.sh

USERNAME="keycloak"

if oc get secret keycloak-postgres-app -n thatdot-openshift >/dev/null 2>&1; then
    echo "Secret 'keycloak-postgres-app' already exists — leaving it alone."
    exit 0
fi

# 32 random base64 chars, stripped of '/' '+' '=' so Postgres URL/JDBC don't
# need URL-encoding tricks. ~190 bits of entropy after stripping.
PASSWORD=$(openssl rand -base64 48 | tr -d '/+=' | head -c 32)

oc create secret generic keycloak-postgres-app \
    --from-literal=username="$USERNAME" \
    --from-literal=password="$PASSWORD" \
    -n thatdot-openshift

echo "Secret 'keycloak-postgres-app' created in namespace thatdot-openshift."
echo "  username: $USERNAME"
echo "  password: <32-char random string, not echoed>"
