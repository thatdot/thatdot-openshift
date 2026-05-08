#!/usr/bin/env bash
set -euo pipefail

# Bootstrap the cluster with OpenShift GitOps + every committed Application CR.
#
# After this script, ArgoCD takes over: it watches the branch each
# Application CR points at and continuously syncs `manifests/*` → cluster.
# This script's job is just to seed that loop.
#
# Idempotent: re-run any time. Every action is `oc apply`, every wait
# tolerates the resource already being ready.
#
# Requires: a running CRC cluster + `oc` authenticated as cluster-admin.
#
# Usage: ./scripts/bootstrap.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ---- Preflight: cluster auth ----
if ! oc whoami >/dev/null 2>&1; then
    echo "ERROR: oc is not authenticated to a cluster."
    echo "  Did you forget: eval \"\$(crc oc-env)\" and 'oc login -u kubeadmin ...'?"
    echo "  See: crc console --credentials"
    exit 1
fi

echo "Logged in as:  $(oc whoami)"
echo "Cluster:       $(oc whoami --show-server)"
echo ""

# ---- Preflight: required env vars ----
# Fail fast if any required env var is missing — collecting them all so the
# user fixes everything in one round-trip rather than fix-rerun-fix-rerun.
missing=()
[[ -z "${QE_LICENSE_KEY:-}" ]] && missing+=("QE_LICENSE_KEY")
[[ -z "${THATDOT_REGISTRY_USERNAME:-}" ]] && missing+=("THATDOT_REGISTRY_USERNAME")
[[ -z "${THATDOT_REGISTRY_PASSWORD:-}" ]] && missing+=("THATDOT_REGISTRY_PASSWORD")

if [[ ${#missing[@]} -gt 0 ]]; then
    echo "ERROR: required environment variable(s) not set:"
    for var in "${missing[@]}"; do
        echo "  - $var"
    done
    echo ""
    echo "These are sourced from ~/.zshrc.local. To set them, append:"
    echo "  export QE_LICENSE_KEY=\"...\""
    echo "  export THATDOT_REGISTRY_USERNAME=\"...\""
    echo "  export THATDOT_REGISTRY_PASSWORD=\"...\""
    echo "Then 'source ~/.zshrc.local' or open a new terminal, and re-run."
    exit 1
fi
echo ""

# ---- Install OpenShift GitOps Operator ----
echo "==> Applying GitOps Operator Subscription..."
oc apply -f "$PROJECT_DIR/bootstrap/gitops-operator-subscription.yaml"
echo ""

echo "==> Waiting for ArgoCD to be ready (up to 10 minutes)..."
echo "    First-time install pulls the operator image and reconciles the ArgoCD CR;"
echo "    this can take several minutes."
TIMEOUT=600
INTERVAL=10
ELAPSED=0
while [[ $ELAPSED -lt $TIMEOUT ]]; do
    if oc rollout status deploy/openshift-gitops-server -n openshift-gitops \
            --timeout=10s >/dev/null 2>&1; then
        echo "    ArgoCD server is ready."
        break
    fi
    sleep $INTERVAL
    ELAPSED=$((ELAPSED + INTERVAL))
    echo "    Still waiting... (${ELAPSED}s / ${TIMEOUT}s)"
done

if [[ $ELAPSED -ge $TIMEOUT ]]; then
    echo ""
    echo "ERROR: ArgoCD did not become ready within ${TIMEOUT}s."
    echo "  Inspect: oc get csv,pods,deploy -A | grep -i gitops"
    exit 1
fi
echo ""

# ---- Configure ArgoCD: enable Kustomize+Helm rendering ----
# Required because manifests/<step>/kustomization.yaml uses helmCharts:
# generators. Without --enable-helm, kustomize ignores those blocks silently.
echo "==> Enabling Kustomize+Helm rendering on the ArgoCD instance..."
oc patch argocd openshift-gitops -n openshift-gitops --type merge \
    -p '{"spec":{"kustomizeBuildOptions":"--enable-helm"}}'
echo ""

# ---- Apply shared cluster resources (namespaces, etc.) ----
# These live in bootstrap/ rather than under any one step's manifests/ because
# they're shared infrastructure across every step. Applied directly via `oc apply`,
# never managed by ArgoCD's prune logic.
echo "==> Applying shared cluster resources..."
applied_core=0
for resource in "$PROJECT_DIR"/bootstrap/namespace-*.yaml; do
    [[ -f "$resource" ]] || continue
    echo "    + $(basename "$resource")"
    oc apply -f "$resource"
    applied_core=$((applied_core + 1))
done
if [[ $applied_core -eq 0 ]]; then
    echo "    (no namespace-*.yaml files in bootstrap/ — nothing to apply)"
fi
echo ""

# ---- Create namespace-scoped secrets ----
# Each create-*-secret.sh script is idempotent (`oc apply --dry-run=client | oc apply -f -`).
# Required env vars were validated above, so these calls won't fail on missing creds.
echo "==> Creating namespace-scoped secrets..."
"$SCRIPT_DIR/create-license-secret.sh"
"$SCRIPT_DIR/create-thatdot-registry-pull-secret.sh"
echo ""

# ---- Apply every Application CR ----
echo "==> Applying Application CRs..."
applied=0
for app in "$PROJECT_DIR"/bootstrap/application-*.yaml; do
    [[ -f "$app" ]] || continue
    echo "    + $(basename "$app")"
    oc apply -f "$app"
    applied=$((applied + 1))
done

if [[ $applied -eq 0 ]]; then
    echo "    (no Application CRs found in bootstrap/ — nothing to seed)"
else
    echo "    Applied $applied Application CR(s)."
fi
echo ""

# ---- Done ----
echo "Done. ArgoCD is bootstrapped; Application(s) seeded."
echo ""
echo "Watch sync progress:"
echo "  oc get application -n openshift-gitops -w"
echo ""

ui_host=$(oc -n openshift-gitops get route openshift-gitops-server \
    -o jsonpath='{.spec.host}' 2>/dev/null || true)
if [[ -n "$ui_host" ]]; then
    echo "ArgoCD UI:"
    echo "  https://$ui_host"
    echo "  (log in via 'LOG IN VIA OPENSHIFT' with kubeadmin)"
fi
