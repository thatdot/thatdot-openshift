#!/usr/bin/env bash
set -euo pipefail

# Creates the QE license Secret in the thatdot-openshift namespace.
# Idempotent: re-runs are safe; updates the secret if the key changed.
#
# Requires:
#   - $QE_LICENSE_KEY in the shell environment (sourced from ~/.zshrc.local)
#   - The thatdot-openshift namespace to exist
#
# Usage: ./scripts/create-license-secret.sh

: "${QE_LICENSE_KEY:?QE_LICENSE_KEY must be set in the shell (e.g., in ~/.zshrc.local)}"

oc create secret generic qe-license \
    --from-literal=license-key="$QE_LICENSE_KEY" \
    -n thatdot-openshift \
    --dry-run=client -o yaml | oc apply -f -

echo "Secret 'qe-license' applied to namespace thatdot-openshift."
