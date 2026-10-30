#!/usr/bin/env bash
# Install Node Feature Discovery and the NVIDIA GPU Operator from the cluster's catalog.
source "$(dirname "$0")/lib.sh"; login
pick() { oc get packagemanifests -n openshift-marketplace -o name | sed 's#.*/##' | grep -E "$1" | head -1; }
install() { local ns=$1 pkg=$2 src chan
  src=$(oc get packagemanifest "$pkg" -n openshift-marketplace -o jsonpath='{.status.catalogSource}')
  chan=$(oc get packagemanifest "$pkg" -n openshift-marketplace -o jsonpath='{.status.defaultChannel}')
  echo "---- $pkg from $src, channel $chan, into $ns"
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
spec: {name: $pkg, channel: "$chan", source: $src, sourceNamespace: openshift-marketplace, installPlanApproval: Automatic}
YAML
}
NFD=$(pick '^nfd$'); NV=$(pick '^gpu-operator-certified$')
[ -n "$NFD" ] && [ -n "$NV" ] || die "nfd or gpu-operator-certified is missing from the catalog."
install openshift-nfd "$NFD"; install nvidia-gpu-operator "$NV"
hr "Waiting for both operators (up to 10 min)"
for i in $(seq 1 60); do
  ok=$(for ns in openshift-nfd nvidia-gpu-operator; do oc get csv -n $ns -o jsonpath='{range .items[*]}{.status.phase}{"\n"}{end}' 2>/dev/null; done | grep -c '^Succeeded$')
  echo "  [$i] ready: $ok/2"; [ "$ok" -ge 2 ] && break; sleep 10
done
[ "$ok" -ge 2 ] || die "Operators did not become ready; check: oc get csv -n openshift-nfd -n nvidia-gpu-operator"
oc get csv -n openshift-nfd; oc get csv -n nvidia-gpu-operator
