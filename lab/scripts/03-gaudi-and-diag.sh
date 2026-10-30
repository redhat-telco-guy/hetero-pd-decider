#!/usr/bin/env bash
# 1) connectivity check  2) apply Gaudi ClusterPolicy  3) dump GPU operator state for diagnosis
set -uo pipefail
PY=$(command -v python3 || command -v python)
hr() { printf '\n==== %s ====\n' "$1"; }

hr "Connectivity"
if ! oc whoami >/dev/null 2>&1; then
  echo "Cannot reach the cluster API. Reconnect VPN/network (and re-run oc login if the token expired), then re-run this script."
  oc whoami 2>&1; exit 1
fi
oc whoami

hr "Gaudi ClusterPolicy (habanalabs.habana.ai/v1)"
if oc get clusterpolicies.habanalabs.habana.ai habana-ai >/dev/null 2>&1; then
  echo "already exists"
else
  csv=$(oc get csv -n habana-ai-operator -o name | grep /habana-ai-operator | head -1)
  oc get "$csv" -n habana-ai-operator -o jsonpath='{.metadata.annotations.alm-examples}' \
   | $PY -c "import json,sys; e=[x for x in json.load(sys.stdin) if x['kind']=='ClusterPolicy']; print(json.dumps(e[0]))" \
   | oc apply -f -
fi

hr "NFD labels on workers (PCI vendor present?)"
for n in worker1 worker2; do
  echo "-- $n"; oc get node $n.ai154.dl154.dfw.ocp.run -o json | $PY -c "
import json,sys
l=json.load(sys.stdin)['metadata']['labels']
for k,v in sorted(l.items()):
    if any(s in k for s in ('pci-10de','pci-1da3','nvidia.com','habana','kernel-version.full','system-os_release')): print('  ',k,'=',v)"
done

hr "NVIDIA ClusterPolicy status"
oc get clusterpolicies.nvidia.com gpu-cluster-policy -o jsonpath='{.status.state}{"\n"}{range .status.conditions[*]}{.type}={.status} {.reason}: {.message}{"\n"}{end}'

hr "NVIDIA pods"
oc get pods -n nvidia-gpu-operator -o wide

hr "NVIDIA driver pod: containers and last logs"
for p in $(oc get pods -n nvidia-gpu-operator -o name | grep -E 'driver'); do
  echo "## $p"
  oc get $p -n nvidia-gpu-operator -o jsonpath='{range .status.initContainerStatuses[*]}init {.name}: ready={.ready} {.state}{"\n"}{end}{range .status.containerStatuses[*]}{.name}: ready={.ready} restarts={.restartCount} {.state}{"\n"}{end}'
  for c in $(oc get $p -n nvidia-gpu-operator -o jsonpath='{.spec.initContainers[*].name} {.spec.containers[*].name}'); do
    echo "--- $c (last 25 lines)"; oc logs $p -n nvidia-gpu-operator -c $c --tail=25 2>&1
  done
done

hr "GPU operator log (last 40)"
oc logs -n nvidia-gpu-operator deploy/gpu-operator --tail=40 2>&1

hr "Recent warning events (nvidia, habana)"
oc get events -n nvidia-gpu-operator --field-selector type=Warning --sort-by=.lastTimestamp 2>&1 | tail -15
oc get events -n habana-ai-operator  --field-selector type=Warning --sort-by=.lastTimestamp 2>&1 | tail -15

hr "Gaudi pods (just created; may still be starting)"
sleep 30; oc get pods -n habana-ai-operator -o wide
