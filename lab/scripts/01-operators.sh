#!/usr/bin/env bash
# Installs NFD, NVIDIA GPU Operator and Intel Gaudi Base Operator via OLM.
# Package names and channels are read from the cluster's catalog, not assumed.
set -euo pipefail

echo "==== Catalog lookup ===="
oc get packagemanifests -n openshift-marketplace \
  -o custom-columns='NAME:.metadata.name,CATALOG:.status.catalogSource,DEFAULT:.status.defaultChannel' \
  | grep -Ei '^NAME|^nfd|gpu-operator|habana|gaudi|intel' || true

pick() {  # pick <regex> -> first matching package name
  oc get packagemanifests -n openshift-marketplace -o name | sed 's#.*/##' | grep -E "$1" | head -1
}
NFD_PKG=$(pick '^nfd$')
NV_PKG=$(pick '^gpu-operator-certified$')
HB_PKG=$(pick 'habana|gaudi')
echo "NFD=$NFD_PKG  NVIDIA=$NV_PKG  GAUDI=$HB_PKG"
[ -n "$NFD_PKG" ] && [ -n "$NV_PKG" ] && [ -n "$HB_PKG" ] || { echo "A package is missing from the catalog; stopping."; exit 1; }

install() {  # install <namespace> <package>
  local ns=$1 pkg=$2
  local src chan
  src=$(oc get packagemanifest "$pkg" -n openshift-marketplace -o jsonpath='{.status.catalogSource}')
  chan=$(oc get packagemanifest "$pkg" -n openshift-marketplace -o jsonpath='{.status.defaultChannel}')
  echo "---- $pkg from $src channel $chan into $ns"
  oc apply -f - <<YAML
apiVersion: v1
kind: Namespace
metadata: {name: $ns}
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata: {name: $ns, namespace: $ns}
spec: {targetNamespaces: [$ns]}
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata: {name: $pkg, namespace: $ns}
spec:
  name: $pkg
  channel: "$chan"
  source: $src
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
YAML
}

install openshift-nfd         "$NFD_PKG"
install nvidia-gpu-operator   "$NV_PKG"
install habana-ai-operator    "$HB_PKG"

echo "==== Waiting for CSVs (up to 10 min) ===="
for i in $(seq 1 60); do
  out=$(oc get csv -n openshift-nfd -n nvidia-gpu-operator 2>/dev/null; \
        for ns in openshift-nfd nvidia-gpu-operator habana-ai-operator; do oc get csv -n $ns --no-headers 2>/dev/null | sed "s#^#$ns #"; done)
  phases=$(for ns in openshift-nfd nvidia-gpu-operator habana-ai-operator; do oc get csv -n $ns -o jsonpath='{range .items[*]}{.status.phase}{"\n"}{end}' 2>/dev/null; done)
  ok=$(echo "$phases" | grep -c '^Succeeded$' || true)
  echo "[$i] succeeded CSVs: $ok/3"
  [ "$ok" -ge 3 ] && break
  sleep 10
done
for ns in openshift-nfd nvidia-gpu-operator habana-ai-operator; do echo "== $ns"; oc get csv,pods -n $ns 2>&1; done
