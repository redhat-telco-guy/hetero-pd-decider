#!/usr/bin/env bash
# Disable MIG on the A30s (whole-GPU mode), then wait for both vendors' cards to be schedulable.
set -uo pipefail
W1=worker1.ai154.dl154.dfw.ocp.run; W2=worker2.ai154.dl154.dfw.ocp.run
hr() { printf '\n==== %s ====\n' "$1"; }
oc whoami >/dev/null 2>&1 || { echo "Cannot reach cluster; reconnect and oc login, then re-run."; exit 1; }

hr "Disable MIG on $W1"
oc label node $W1 nvidia.com/mig.config=all-disabled --overwrite

hr "Waiting for MIG manager (state should go pending -> success)"
for i in $(seq 1 40); do
  st=$(oc get node $W1 -o jsonpath='{.metadata.labels.nvidia\.com/mig\.config\.state}')
  echo "[$i $(date +%H:%M:%S)] mig.config.state=${st:-<none>}"
  [ "$st" = "success" ] && break
  [ "$st" = "failed" ] && { echo "MIG manager failed:"; oc logs -n nvidia-gpu-operator -l app=nvidia-mig-manager --tail=40; break; }
  sleep 15
done

hr "Restart device plugin and validator so they pick up whole GPUs"
oc delete pod -n nvidia-gpu-operator -l app=nvidia-device-plugin-daemonset --wait=false
oc delete pod -n nvidia-gpu-operator -l app=nvidia-operator-validator --wait=false

hr "Waiting for nvidia.com/gpu and habana.ai/gaudi (up to 20 min)"
for i in $(seq 1 80); do
  nv=$(oc get node $W1 -o jsonpath='{.status.allocatable.nvidia\.com/gpu}')
  hb=$(oc get node $W2 -o jsonpath='{.status.allocatable.habana\.ai/gaudi}')
  prod=$(oc get node $W1 -o jsonpath='{.metadata.labels.nvidia\.com/gpu\.product}')
  echo "[$i $(date +%H:%M)] worker1 nvidia.com/gpu=${nv:-0} ($prod)  worker2 habana.ai/gaudi=${hb:-0}"
  [ "${nv:-0}" -ge 1 ] && [ "${hb:-0}" -ge 1 ] && break
  sleep 15
done

hr "Final"
oc get nodes -o custom-columns='NAME:.metadata.name,A30:.status.allocatable.nvidia\.com/gpu,GAUDI:.status.allocatable.habana\.ai/gaudi,PRODUCT:.metadata.labels.nvidia\.com/gpu\.product'
oc get clusterpolicies.nvidia.com gpu-cluster-policy -o jsonpath='NVIDIA ClusterPolicy: {.status.state}{"\n"}'
oc get pods -n nvidia-gpu-operator | grep -v Completed
oc get pods -n habana-ai-operator -o wide
echo "--- Gaudi driver loader logs (last 30)"
for p in $(oc get pods -n habana-ai-operator -o name | grep -i driver); do echo "## $p"; oc logs $p -n habana-ai-operator --all-containers --tail=30 2>&1; done
oc get events -n habana-ai-operator --field-selector type=Warning --sort-by=.lastTimestamp | grep -v servicemonitor | tail -10
