#!/usr/bin/env bash
# Watch the Gaudi engine. If it dies again with "Host malloc failed", raise the pod's RAM
# (worker2 has ~500 GB) and cap the KV cache share of HBM, then restart it once.
set -uo pipefail
NS=hetero-pd-lab
REPO=$(cd "$(dirname "$0")/../.." && pwd); DEC=$REPO/lab/modelserver/layout-a-a30-prefill/decode-gaudi3.yaml
oc whoami >/dev/null 2>&1 || { echo "Cannot reach cluster; reconnect and oc login, then re-run."; exit 1; }
pod() { oc get pods -n $NS -l app=decode-gaudi3 --sort-by=.metadata.creationTimestamp -o name | tail -1; }

fix_applied=no
for i in $(seq 1 120); do
  P=$(pod)
  R=$(oc get $P -n $NS -o jsonpath='{.status.containerStatuses[?(@.name=="modelserver")].ready}')
  N=$(oc get $P -n $NS -o jsonpath='{.status.containerStatuses[?(@.name=="modelserver")].restartCount}')
  L=$(oc logs $P -n $NS -c modelserver --tail=1 2>/dev/null | tr '\r' '\n' | tail -1 | cut -c1-110)
  echo "[$i $(date +%H:%M)] ready=$R restarts=$N | $L"
  [ "$R" = true ] && { echo "GAUDI DECODE: READY"; break; }
  if [ "${N:-0}" -ge 2 ] && [ $fix_applied = no ] && \
     oc logs $P -n $NS -c modelserver --previous 2>/dev/null | grep -q 'Host malloc failed'; then
    echo "Crashed again with Host malloc failed -> raising RAM to 320Gi and capping HBM use at 0.75"
    sed -i -e 's/^              memory: 96Gi$/              memory: 192Gi/' \
           -e 's/^              memory: 128Gi$/              memory: 320Gi/' "$DEC"
    grep -q -- '--gpu-memory-utilization' "$DEC" || \
      sed -i 's/^            - "--max-model-len=8192"$/            - "--max-model-len=8192"\n            - "--gpu-memory-utilization=0.75"/' "$DEC"
    oc apply -n $NS -k $REPO/lab/modelserver/layout-a-a30-prefill
    fix_applied=yes; sleep 30
  fi
  sleep 15
done
oc get pods -n $NS -o wide | grep -v build
P=$(pod); oc logs $P -n $NS -c modelserver 2>/dev/null | grep -iE 'KV cache|nixl|Warmup finished|warmup.*took|memory' | tail -10 | cut -c1-220
