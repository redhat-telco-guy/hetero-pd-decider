#!/usr/bin/env bash
# Install the GPU stack on the rebuilt lab: Node Feature Discovery, NVIDIA GPU Operator, Kernel Module
# Management and the Intel Gaudi Base Operator; create their policies; turn MIG off on the A30s; wait
# for the drivers to load; then run the card health check (temperatures, boot errors).
#   bash lab/scripts/37-gpu-operators.sh 2>&1 | tee 37-gpu-operators.txt
set -uo pipefail
REPO=$(cd "$(dirname "$0")/../.." && pwd); S=$REPO/lab/scripts; PY=$(command -v python3 || command -v python)
hr() { printf '\n==== %s ====\n' "$1"; }
oc whoami >/dev/null 2>&1 || { echo "Not logged in. Run oc login first."; exit 1; }
example() { local ns=$1 prefix=$2 kind=$3 csv
  csv=$(oc get csv -n "$ns" -o name | grep "/$prefix" | head -1)   # the operator's own CSV, not a copy
  oc get "$csv" -n "$ns" -o jsonpath='{.metadata.annotations.alm-examples}' \
   | $PY -c "import json,sys; ex=[e for e in json.load(sys.stdin) if e['kind']=='$kind']; print(json.dumps(ex[0]) if ex else '')"; }

hr "1. Operators: NFD, NVIDIA GPU Operator, Intel Gaudi Base Operator"
bash $S/01-operators.sh 2>&1 | grep -E '^NFD=|^----|succeeded CSVs|Succeeded|Failed|missing' | tail -12

hr "2. Kernel Module Management (builds the Gaudi driver)"
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
  for i in $(seq 1 40); do oc get csv -n openshift-kmm -o jsonpath='{.items[*].status.phase}' 2>/dev/null | grep -q Succeeded && break; sleep 10; done
fi
oc get csv -n openshift-kmm --no-headers 2>/dev/null | grep -i kernel-module | awk '{print "  "$1, $NF}'

hr "3. Policies: NFD instance, NVIDIA ClusterPolicy, Gaudi ClusterPolicy"
oc get nodefeaturediscoveries.nfd.openshift.io -n openshift-nfd -o name 2>/dev/null | grep -q . || example openshift-nfd nfd NodeFeatureDiscovery | oc apply -n openshift-nfd -f -
oc get clusterpolicies.nvidia.com -o name 2>/dev/null | grep -q . || example nvidia-gpu-operator gpu-operator-certified ClusterPolicy | oc apply -f -
if ! oc get clusterpolicies.habanalabs.habana.ai -o name 2>/dev/null | grep -q .; then
  SAVED=$(ls -d $REPO/lab-archive/*/operators/gaudi-clusterpolicy.yaml 2>/dev/null | tail -1)
  if [ -n "$SAVED" ] && $PY -c "import yaml" 2>/dev/null; then echo "  using the Gaudi ClusterPolicy saved from the first lab ($SAVED)"
    $PY - "$SAVED" <<'PY' | oc apply -f -
import sys, yaml, json
d = yaml.safe_load(open(sys.argv[1])); it = d["items"][0] if d.get("items") else d
print(json.dumps({"apiVersion": it["apiVersion"], "kind": it["kind"], "metadata": {"name": it["metadata"]["name"]}, "spec": it["spec"]}))
PY
  else example habana-ai-operator habana-ai-operator ClusterPolicy | oc apply -f -; fi
fi

hr "4. Turn MIG off on the A30s (workaround: they came up MIG-INVALID last time)"
for i in $(seq 1 40); do N=$(oc get nodes -l feature.node.kubernetes.io/pci-10de.present=true -o name); [ -n "$N" ] && break; sleep 15; done
for n in $N; do oc label $n nvidia.com/mig.config=all-disabled --overwrite; done

hr "5. Waiting for the drivers (NVIDIA driver build + Gaudi driver build: 15-30 min)"
for i in $(seq 1 120); do
  nv=0; for n in $(oc get nodes -l feature.node.kubernetes.io/pci-10de.present=true -o name); do v=$(oc get $n -o jsonpath='{.status.allocatable.nvidia\.com/gpu}' 2>/dev/null); nv=$((nv + ${v:-0})); done
  hb=0; for n in $(oc get nodes -l feature.node.kubernetes.io/pci-1da3.present=true -o name); do v=$(oc get $n -o jsonpath='{.status.allocatable.habana\.ai/gaudi}' 2>/dev/null); hb=$((hb + ${v:-0})); done
  echo "  [$i $(date +%H:%M)] schedulable A30s: ${nv:-0}/2   Gaudis: ${hb:-0}/2"
  [ "${nv:-0}" -ge 2 ] && [ "${hb:-0}" -ge 2 ] && break
  [ $i -eq 40 ] && oc delete pod -n nvidia-gpu-operator -l app=nvidia-device-plugin-daemonset --wait=false >/dev/null 2>&1
  # A Gaudi that fails at driver load never becomes schedulable; stop waiting once its driver has tried.
  if [ $i -ge 60 ] && [ "${nv:-0}" -ge 2 ] && [ "${hb:-0}" -ge 1 ]; then echo "  one Gaudi is still missing after 15 min; checking why below"; break; fi
  sleep 15
done
oc get pods -n habana-ai-operator -o wide 2>&1 | head -12
oc get pods -n nvidia-gpu-operator 2>&1 | grep -vE 'Completed' | head -20

hr "6. Card health with drivers loaded (temperatures, boot errors)"
sleep 60   # let the metric exporter take its first reading
bash $S/36-card-health.sh 2>&1 | sed -n '/Hardware on each/,$p'
