#!/usr/bin/env bash
set -euo pipefail

# Bootstrap the cluster for app-of-apps GitOps.
#
# Imperative phase (this script):
#   1. Install OpenShift GitOps Operator + wait for ArgoCD ready
#   2. Patch ArgoCD with our customizations (--enable-helm + CassandraDatacenter health check)
#   3. Apply the shared workload namespace (preconditional; ArgoCD needs the
#      managed-by label active before it can sync into the namespace)
#   4. Create out-of-band secrets (license, registry pull-secret) from env vars
#   5. Seed the root Application — ArgoCD takes over from here
#
# After this script, ArgoCD owns everything else. The cascade is:
#   root --> application-platform (wave 0) --> cass-operator-subscription, application-cassandra
#        \-> application-product  (wave 1) --> application-quine-enterprise
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

# ---- Configure ArgoCD: kustomize+helm + custom resource health checks ----
# bootstrap/argocd-customizations.yaml carries:
#   - kustomizeBuildOptions: --enable-helm  (so kustomize honors helmCharts: blocks)
#   - resourceHealthChecks for CRDs ArgoCD doesn't know about natively (CassandraDatacenter)
echo "==> Patching ArgoCD instance with customizations (Kustomize+Helm, CassandraDatacenter health check)..."
oc patch argocd openshift-gitops -n openshift-gitops --type merge \
    --patch-file "$PROJECT_DIR/bootstrap/argocd-customizations.yaml"
echo ""

# ---- Apply the shared namespace (preconditional) ----
# Stays imperative because:
#   1. The OpenShift GitOps Operator watches namespaces for the managed-by label
#      and creates the RoleBinding asynchronously. If we let GitOps create the
#      namespace, the first wrapper sync races with the operator's RoleBinding
#      provisioning and fails "forbidden" until ArgoCD retries.
#   2. The secrets created below are namespace-scoped and need this namespace
#      to exist already.
echo "==> Applying shared workload namespace..."
oc apply -f "$PROJECT_DIR/bootstrap/namespace-thatdot-openshift.yaml"
echo ""

# ---- Create namespace-scoped secrets ----
# Each create-*-secret.sh script is idempotent (`oc apply --dry-run=client | oc apply -f -`).
# Required env vars were validated above, so these calls won't fail on missing creds.
echo "==> Creating namespace-scoped secrets..."
"$SCRIPT_DIR/create-license-secret.sh"
"$SCRIPT_DIR/create-thatdot-registry-pull-secret.sh"
"$SCRIPT_DIR/create-keycloak-postgres-secret.sh"
echo ""

# ---- Seed the root Application ----
# Everything else flows from this single CR. ArgoCD now owns the cascade:
#   root --> application-platform (wave 0) --> cass-operator-subscription, application-cassandra
#        \-> application-product  (wave 1) --> application-quine-enterprise
echo "==> Seeding root Application..."
oc apply -f "$PROJECT_DIR/bootstrap/root-application.yaml"
echo ""

# ---- Done ----
echo "Done. ArgoCD is bootstrapped; root Application seeded."
echo ""
echo "Watch the cascade (root → platform → product, ~5-7 min cold-start):"
echo "  oc get application -n openshift-gitops -w"
echo ""

ui_host=$(oc -n openshift-gitops get route openshift-gitops-server \
    -o jsonpath='{.spec.host}' 2>/dev/null || true)
if [[ -n "$ui_host" ]]; then
    echo "ArgoCD UI:"
    echo "  https://$ui_host"
    echo "  (log in via 'LOG IN VIA OPENSHIFT' with kubeadmin)"
fi
