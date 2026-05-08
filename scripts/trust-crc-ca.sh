#!/usr/bin/env bash
set -euo pipefail

# Extracts the OpenShift ingress CA from the running CRC cluster and adds it
# to the macOS System keychain so browsers trust *.apps-crc.testing routes
# (OpenShift web console, our future workloads).
#
# Idempotent: prior CRC ingress entries (both the CA and any leaf certs that
# may have been mis-trusted by earlier versions of this script) are removed
# before the new CA is added.
#
# Requires: a running CRC cluster + `oc` authenticated as kubeadmin.
# Note: Firefox uses its own trust store — import temp/crc-ingress-ca.crt
#       manually via Preferences > Privacy & Security > Certificates.
#
# Usage: ./scripts/trust-crc-ca.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
KEYCHAIN="/Library/Keychains/System.keychain"

TEMP_DIR="$PROJECT_DIR/temp"
CA_BUNDLE="$TEMP_DIR/crc-ingress-ca.crt"
SPLIT_DIR="$TEMP_DIR/crc-ingress-split"

# Cleanup matches: CRC ingress CA CNs look like "ingress-operator@1731089234",
# leaf certs are "*.apps-crc.testing".
CLEANUP_PATTERNS=("ingress-operator" "apps-crc.testing")

mkdir -p "$TEMP_DIR"
rm -rf "$SPLIT_DIR"
mkdir -p "$SPLIT_DIR"

# ---- Preflight ----
if ! oc whoami >/dev/null 2>&1; then
    echo "ERROR: oc is not authenticated to a cluster."
    echo "  Did you forget: eval \"\$(crc oc-env)\" and 'oc login -u kubeadmin ...'?"
    echo "  See: crc console --credentials"
    exit 1
fi

# ---- Extract the ingress CA bundle ----
echo "Extracting OpenShift ingress CA bundle from cluster..."
oc get configmap -n openshift-config-managed default-ingress-cert \
    -o jsonpath='{.data.ca-bundle\.crt}' > "$CA_BUNDLE"

if [[ ! -s "$CA_BUNDLE" ]]; then
    echo "ERROR: ingress CA bundle was empty."
    echo "  Confirm cluster admin: 'oc whoami' should print 'kubeadmin'."
    rm -f "$CA_BUNDLE"
    exit 1
fi

# ---- Cleanup: remove any prior CRC-related certs from the keychain ----
echo "Removing any prior CRC certs from System keychain..."
total_removed=0
for pattern in "${CLEANUP_PATTERNS[@]}"; do
    prior_hashes=$(security find-certificate -a -Z -c "$pattern" "$KEYCHAIN" 2>/dev/null \
        | awk '/^SHA-1 hash:/ {print $NF}')
    if [[ -n "$prior_hashes" ]]; then
        while IFS= read -r sha1; do
            if sudo security delete-certificate -Z "$sha1" "$KEYCHAIN" >/dev/null 2>&1; then
                total_removed=$((total_removed + 1))
            fi
        done <<< "$prior_hashes"
    fi
done
echo "  Removed $total_removed prior cert(s)."

# ---- Split the bundle into individual cert files ----
# `security add-trusted-cert` only trusts the FIRST cert in a multi-cert file,
# so we split and process each separately.
awk -v dir="$SPLIT_DIR" '
    /-----BEGIN CERTIFICATE-----/ { i++; out = sprintf("%s/cert-%02d.pem", dir, i) }
    { print > out }
' "$CA_BUNDLE"

# ---- Add only the self-signed root(s) as trusted ----
# Trusting a leaf as trustRoot is semantically wrong and clutters the keychain.
echo "Trusting self-signed root CA(s) from bundle..."
trusted=0
for cert in "$SPLIT_DIR"/cert-*.pem; do
    [[ -f "$cert" ]] || continue
    subject=$(openssl x509 -in "$cert" -noout -subject -nameopt RFC2253 | sed 's/^subject=//')
    issuer=$(openssl x509 -in "$cert" -noout -issuer -nameopt RFC2253 | sed 's/^issuer=//')
    if [[ "$subject" == "$issuer" ]]; then
        echo "  + $subject  (self-signed root)"
        sudo security add-trusted-cert -d -r trustRoot -k "$KEYCHAIN" "$cert"
        trusted=$((trusted + 1))
    else
        echo "  - $subject  (skipped — leaf cert, issuer: $issuer)"
    fi
done

if [[ $trusted -eq 0 ]]; then
    echo "ERROR: no self-signed root CA found in the bundle."
    echo "  This is unexpected; the bundle should contain the ingress-operator CA."
    exit 1
fi

echo ""
echo "Done. $trusted CA(s) trusted as root in System keychain."
echo "Chrome and Safari now trust *.apps-crc.testing routes."
echo "Firefox: import individual certs from $SPLIT_DIR/ manually."
echo ""
echo "If Chrome still shows a warning, fully quit Chrome (Cmd+Q) and reopen —"
echo "Chrome aggressively caches cert decisions per-session."
