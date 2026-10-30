#!/usr/bin/env bash
# Creates NFD, NVIDIA ClusterPolicy and Gaudi DeviceConfig from each operator's
# built-in example (alm-examples), installs KMM, then waits for the cards to appear.
set -euo pipefail
PY=$(command -v python3 || command -v python)

example() {  # example <namespace> <csv-name-prefix> <kind> -> that CR as JSON
  local ns=$1 prefix=$2 kind=$3 csv
  # Pick the operator's own CSV by name; cluster-wide operators (KMM) leave copies in every namespace.
  csv=$(oc get csv -n "$ns" -o name | grep "/$prefix" | head -1)
  [ -n "$csv" ] || { echo "No CSV matching $prefix in $ns" >&2; return 1; }
  oc get "$csv" -n "$ns" -o jsonpath='{.metadata.annotations.alm-examples}' \
   | $PY -c "import json,sys; ex=[e for e in json.load(sys.stdin) if e['kind']=='$kind']; print(json.dumps(ex[0]) if ex else '')"
}

echo "==== 1. Kernel Module Management (needed by the Gaudi driver) ===="
if ! oc get csv -A 2>/dev/null | grep -qi kernel-module-management; then
  src=$(oc get packagemanifest kernel-module-management -n openshift-marketplace -o jsonpath='{.status.catalogSource}')
  chan=$(oc get packagemanifest kernel-module-management -n openshift-marketplace -o jsonpath='{.status.defaultChannel}')
  oc apply -f - <<YAML
apiVersion: v1
kind: Namespace
metadata: {name: openshift-kmm}
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata: {name: kmm, namespace: openshift-kmm}
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata: {name: kernel-module-management, namespace: openshift-kmm}
spec: {name: kernel-module-management, channel: "$chan", source: $src, sourceNamespace: openshift-marketplace}
YAML
  for i in $(seq 1 40); do
    oc get csv -n openshift-kmm -o jsonpath='{.items[*].status.phase}' 2>/dev/null | grep -q Succeeded && break; sleep 10
  done
fi
oc get csv -n openshift-kmm

echo "==== 2. NodeFeatureDiscovery ===="
J=$(example openshift-nfd nfd NodeFeatureDiscovery); [ -n "$J" ] || { echo "No NodeFeatureDiscovery example"; exit 1; }; echo "$J" | $PY -m json.tool
echo "$J" | oc apply -n openshift-nfd -f -

echo "==== 3. NVIDIA ClusterPolicy ===="
J=$(example nvidia-gpu-operator gpu-operator-certified ClusterPolicy); [ -n "$J" ] || { echo "No ClusterPolicy example"; exit 1; }; echo "$J" | $PY -m json.tool | head -60
echo "$J" | oc apply -f -

echo "==== 4. Gaudi DeviceConfig ===="
oc get csv -n habana-ai-operator -o name | grep /habana-ai-operator | head -1 | xargs -I{} oc get {} -n habana-ai-operator -o jsonpath='{.metadata.annotations.alm-examples}' | $PY -m json.tool
J=$(example habana-ai-operator habana-ai-operator DeviceConfig || true)
if [ -n "$J" ]; then echo "$J" | oc apply -n habana-ai-operator -f -; else echo "No DeviceConfig example found; stopping here for review."; fi

echo "==== 5. Waiting for nvidia.com/gpu and habana.ai/gaudi (up to 25 min; driver builds take a while) ===="
for i in $(seq 1 100); do
  nv=$(oc get node worker1.ai154.dl154.dfw.ocp.run -o jsonpath='{.status.allocatable.nvidia\.com/gpu}')
  hb=$(oc get node worker2.ai154.dl154.dfw.ocp.run -o jsonpath='{.status.allocatable.habana\.ai/gaudi}')
  echo "[$i $(date +%H:%M)] worker1 nvidia.com/gpu=${nv:-0}  worker2 habana.ai/gaudi=${hb:-0}"
  [ "${nv:-0}" -ge 1 ] && [ "${hb:-0}" -ge 1 ] && break
  sleep 15
done

echo "==== Final state ===="
oc get nodes -o custom-columns='NAME:.metadata.name,A30:.status.allocatable.nvidia\.com/gpu,GAUDI:.status.allocatable.habana\.ai/gaudi,PRODUCT:.metadata.labels.nvidia\.com/gpu\.product'
for ns in openshift-nfd nvidia-gpu-operator habana-ai-operator openshift-kmm; do echo "== $ns"; oc get pods -n $ns 2>&1; done
oc get clusterpolicy -o jsonpath='{.items[0].status.state}{"\n"}' 2>&1
