#!/usr/bin/env bash
set -uo pipefail

# Validates the manifest tree, Kustomize rendering, and helper scripts.
# Same checks the .github/workflows/validate.yml workflow runs — install the
# tools locally and you can reproduce CI before pushing.
#
# Tools required:
#   yamllint, shellcheck, kustomize, helm, kubeconform
#
# macOS install:
#   brew install yamllint shellcheck kustomize helm kubeconform
#
# Usage: ./ci/validate.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR" || exit 1

# ---- Tool check ----
missing=()
for tool in yamllint shellcheck kustomize helm kubeconform; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
done
if [[ ${#missing[@]} -gt 0 ]]; then
    echo "ERROR: missing required tools: ${missing[*]}"
    echo "  macOS install: brew install ${missing[*]}"
    exit 1
fi

# Run all checks, collecting failures rather than aborting on the first one —
# so the developer sees the full picture in a single run.
failed=()

echo "==> yamllint"
yamllint . || failed+=("yamllint")

echo ""
echo "==> shellcheck scripts/*.sh ci/*.sh"
shellcheck scripts/*.sh ci/*.sh || failed+=("shellcheck")

echo ""
echo "==> kustomize + kubeconform per leaf"
for leaf in manifests/root manifests/platform manifests/product manifests/cassandra manifests/keycloak manifests/quine-enterprise; do
    echo "  --- $leaf ---"
    if ! kustomize build --enable-helm "$leaf" \
            | kubeconform --strict --ignore-missing-schemas --summary; then
        failed+=("$leaf")
    fi
done

echo ""
if [[ ${#failed[@]} -gt 0 ]]; then
    echo "FAILED: ${failed[*]}"
    exit 1
fi
echo "All checks passed."
