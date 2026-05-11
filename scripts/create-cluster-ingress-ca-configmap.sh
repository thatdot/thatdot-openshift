#!/usr/bin/env bash
set -euo pipefail

# Creates/updates the `cluster-ingress-ca` ConfigMap in the thatdot-openshift
# namespace, holding the OpenShift cluster's ingress-operator CA bundle.
# Consumed by the QE pod's `build-truststore` init container (imports into
# the JVM truststore so QE can validate Keycloak's Route TLS) and by the
# `wait-for-keycloak` init container (passed to curl via --cacert).
#
# Why this isn't a GitOps-managed resource:
#   The OpenShift CNO's `config.openshift.io/inject-trusted-cabundle: "true"`
#   label injects the cluster's *proxy* CA bundle (public CAs +
#   additionalTrustBundle from the cluster Proxy config), NOT the cluster's
#   own ingress-operator CA. The ingress CA lives separately at
#   `openshift-config-managed/default-ingress-cert`. This script bridges that
#   gap by copying the ingress CA into a namespaced ConfigMap that
#   restricted-v2 pods can mount.
#
#   (`trust-crc-ca.sh` extracts from the same source — that script lands the
#   CA in the macOS keychain so browsers trust the cluster Routes; this
#   script lands the same CA into a ConfigMap so the QE pod's JVM trusts
#   them. Different consumers, same source.)
#
# Idempotency:
#   `oc apply` from a dry-run-rendered manifest. Re-running the script
#   updates the ConfigMap in place if the CA has changed (e.g., after
#   `crc delete` + `crc start` regenerates the cluster CA).
#
# Prerequisites:
#   - `oc` authenticated as a user that can read
#     `openshift-config-managed/default-ingress-cert` (cluster-admin works;
#     `system:openshift-managed-config-readers` ClusterRole if you want least-priv).
#   - thatdot-openshift namespace exists.
#
# Usage: ./scripts/create-cluster-ingress-ca-configmap.sh

CMNAME="cluster-ingress-ca"
NS="thatdot-openshift"

echo "Extracting cluster ingress CA from openshift-config-managed/default-ingress-cert..."
CA=$(oc get configmap default-ingress-cert -n openshift-config-managed \
    -o jsonpath='{.data.ca-bundle\.crt}')

if [[ -z "$CA" ]]; then
    echo "ERROR: openshift-config-managed/default-ingress-cert has no ca-bundle.crt key."
    echo "       This usually means the cluster ingress operator hasn't finished bootstrap."
    exit 1
fi

# `oc create --dry-run=client -o yaml | oc apply -f -` is the canonical idempotent
# upsert: creates if missing, updates if existing, idempotent on re-run.
oc create configmap "$CMNAME" \
    --from-literal=ca-bundle.crt="$CA" \
    -n "$NS" \
    --dry-run=client -o yaml | oc apply -f -

echo "ConfigMap '$CMNAME' applied to namespace '$NS'."
echo "  source: openshift-config-managed/default-ingress-cert"
echo "  cert count: $(echo "$CA" | grep -c 'BEGIN CERTIFICATE')"
