#!/usr/bin/env bash
# Create NFD and the NVIDIA ClusterPolicy from the operators' own examples, turn MIG off, wait for whole A30s.
source "$(dirname "$0")/lib.sh"; login
example() { local ns=$1 prefix=$2 kind=$3 csv
  csv=$(oc get csv -n "$ns" -o name | grep "/$prefix" | head -1)   # the operator's own CSV, not a copied one
  oc get "$csv" -n "$ns" -o jsonpath='{.metadata.annotations.alm-examples}' \
   | python3 -c "import json,sys; ex=[e for e in json.load(sys.stdin) if e['kind']=='$kind']; print(json.dumps(ex[0]) if ex else '')"; }
hr "NodeFeatureDiscovery"
oc get nodefeaturediscoveries.nfd.openshift.io -n openshift-nfd -o name 2>/dev/null | grep -q . || example openshift-nfd nfd NodeFeatureDiscovery | oc apply -n openshift-nfd -f -
hr "NVIDIA ClusterPolicy (driver, device plugin, MIG manager, monitoring)"
oc get clusterpolicies.nvidia.com -o name 2>/dev/null | grep -q . || example nvidia-gpu-operator gpu-operator-certified ClusterPolicy | oc apply -f -
hr "Waiting for NFD to find the NVIDIA nodes (up to 10 min)"
for i in $(seq 1 40); do N=$(nvidia_nodes); [ -n "$N" ] && break; echo "  [$i] waiting"; sleep 15; done
[ -n "$N" ] || die "No node with an NVIDIA PCI device was found."
echo "$N" | sed 's/^/  NVIDIA node: /'
hr "Turn MIG off on every NVIDIA node"
# Workaround: the A30 came up as MIG-INVALID with the default policy; whole-GPU mode needs this label.
for n in $N; do oc label node $n nvidia.com/mig.config=all-disabled --overwrite; done
hr "Waiting for $GPUS_NEEDED whole A30s (driver build takes 10-25 min the first time)"
for i in $(seq 1 120); do
  t=$(a30_total); st=$(oc get clusterpolicies.nvidia.com -o jsonpath='{.items[0].status.state}' 2>/dev/null)
  echo "  [$i $(date +%H:%M)] A30s allocatable: $t  ClusterPolicy: ${st:-?}"
  [ "$t" -ge "$GPUS_NEEDED" ] && break
  # Workaround: after the MIG change the device plugin sometimes keeps the old view; restart it once.
  [ $i -eq 40 ] && oc delete pod -n nvidia-gpu-operator -l app=nvidia-device-plugin-daemonset --wait=false
  sleep 15
done
[ "$(a30_total)" -ge "$GPUS_NEEDED" ] || die "Fewer than $GPUS_NEEDED A30s are schedulable. Check: oc get pods -n nvidia-gpu-operator"
oc get nodes -l nvidia.com/gpu.product=$A30_PRODUCT -o custom-columns='NODE:.metadata.name,A30S:.status.allocatable.nvidia\.com/gpu,MIG:.metadata.labels.nvidia\.com/mig\.config\.state'
