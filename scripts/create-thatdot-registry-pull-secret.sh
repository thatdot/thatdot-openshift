#!/usr/bin/env bash
set -euo pipefail

# Creates the image-pull Secret for thatDot's private registry in the
# thatdot-openshift namespace. Pods reference this secret via
# `imagePullSecrets: [{name: thatdot-registry-creds}]` (configured in
# manifests/quine-enterprise/values.yaml).
# Idempotent: re-runs are safe; updates the secret if the credentials changed.
#
# Requires:
#   - $THATDOT_REGISTRY_USERNAME and $THATDOT_REGISTRY_PASSWORD in the shell env
#     (sourced from ~/.zshrc.local)
#   - The thatdot-openshift namespace to exist
#
# Usage: ./scripts/create-thatdot-registry-pull-secret.sh

: "${THATDOT_REGISTRY_USERNAME:?THATDOT_REGISTRY_USERNAME must be set in the shell}"
: "${THATDOT_REGISTRY_PASSWORD:?THATDOT_REGISTRY_PASSWORD must be set in the shell}"

oc create secret docker-registry thatdot-registry-creds \
    --docker-server=registry.license-server.dev.thatdot.com \
    --docker-username="$THATDOT_REGISTRY_USERNAME" \
    --docker-password="$THATDOT_REGISTRY_PASSWORD" \
    -n thatdot-openshift \
    --dry-run=client -o yaml | oc apply -f -

echo "Secret 'thatdot-registry-creds' applied to namespace thatdot-openshift."
