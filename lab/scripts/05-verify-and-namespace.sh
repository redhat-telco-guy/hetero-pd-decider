#!/usr/bin/env bash
# Verify accelerators, check build options, create the lab namespace + HF secret.
set -uo pipefail
W1=worker1.ai154.dl154.dfw.ocp.run; W2=worker2.ai154.dl154.dfw.ocp.run; NS=hetero-pd-lab
hr() { printf '\n==== %s ====\n' "$1"; }
oc whoami >/dev/null 2>&1 || { echo "Cannot reach cluster; reconnect and oc login, then re-run."; exit 1; }

hr "Accelerators (waiting up to 5 min for 2 + 2)"
for i in $(seq 1 20); do
  nv=$(oc get node $W1 -o jsonpath='{.status.allocatable.nvidia\.com/gpu}')
  hb=$(oc get node $W2 -o jsonpath='{.status.allocatable.habana\.ai/gaudi}')
  echo "[$i] A30=${nv:-0} Gaudi=${hb:-0}"
  [ "${nv:-0}" -ge 2 ] && [ "${hb:-0}" -ge 2 ] && break; sleep 15
done
oc get node $W2 -o json | python3 -c "import json,sys; l=json.load(sys.stdin)['metadata']['labels']; [print('  ',k,'=',v) for k,v in sorted(l.items()) if 'habana' in k or 'gaudi' in k]"
oc get clusterpolicies.nvidia.com gpu-cluster-policy -o jsonpath='NVIDIA ClusterPolicy: {.status.state}{"\n"}'
oc get pods -n nvidia-gpu-operator | grep -Ev 'Completed|1/1|2/2' || echo "all NVIDIA pods ready"

hr "Build options"
echo "Mac CPU: $(uname -m)"
oc get configs.imageregistry.operator.openshift.io cluster -o jsonpath='Internal registry managementState: {.spec.managementState}  storage: {.spec.storage}{"\n"}'
oc get pods -n openshift-image-registry -l docker-registry=default 2>&1 | head -3
oc get route -n openshift-image-registry 2>&1 | head -3
oc get buildconfig -A 2>/dev/null | head -1 >/dev/null && echo "Builds API available"
oc get clusterversion version -o jsonpath='Capabilities enabled: {.status.capabilities.enabledCapabilities}{"\n"}'

hr "Lab namespace + Hugging Face secret"
oc get ns $NS >/dev/null 2>&1 || oc new-project $NS >/dev/null && echo "namespace $NS ready"
if oc get secret llm-d-hf-token -n $NS >/dev/null 2>&1; then
  echo "secret llm-d-hf-token already exists"
else
  if [ -z "${HF_TOKEN:-}" ]; then
    printf "Paste your Hugging Face token (input hidden), then Enter: "; read -rs HF_TOKEN; echo
  fi
  [ -n "$HF_TOKEN" ] && oc create secret generic llm-d-hf-token --from-literal=HF_TOKEN="$HF_TOKEN" -n $NS \
    && echo "secret created" || echo "No token given; skipped. Re-run this script when you have it."
fi
oc get secret llm-d-hf-token -n $NS -o jsonpath='secret present, key: {range .data}{@}{end}' >/dev/null 2>&1 && echo "secret OK"
