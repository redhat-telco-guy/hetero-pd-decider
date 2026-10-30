#!/usr/bin/env bash
# Deploy layout A (A30 prefill + Gaudi decode) with Qwen2.5-7B, wait, smoke-test both engines.
set -uo pipefail
NS=hetero-pd-lab; MODEL=Qwen/Qwen2.5-7B-Instruct
REPO=$(cd "$(dirname "$0")/../.." && pwd)
hr() { printf '\n==== %s ====\n' "$1"; }
oc whoami >/dev/null 2>&1 || { echo "Cannot reach cluster; reconnect and oc login, then re-run."; exit 1; }

hr "Apply layout A"
oc apply -n $NS -k $REPO/lab/modelserver/layout-a-a30-prefill

state() {  # state <app> -> one-line status
  local P; P=$(oc get pods -n $NS -l app=$1 --sort-by=.metadata.creationTimestamp -o name | tail -1)
  [ -z "$P" ] && { echo "no pod"; return; }
  echo "$(oc get $P -n $NS -o jsonpath='{.status.phase} ready={.status.containerStatuses[?(@.name=="modelserver")].ready} {.status.containerStatuses[?(@.name=="modelserver")].state.waiting.reason}{.status.containerStatuses[?(@.name=="modelserver")].state.terminated.reason}')"
}
lastlog() { oc logs -n $NS deploy/$1 -c modelserver --tail=1 2>/dev/null | cut -c1-110; }

hr "Waiting for both engines (A30 ~5 min; Gaudi download + graph warm-up 15-30 min)"
for i in $(seq 1 140); do
  A=$(state prefill-a30); G=$(state decode-gaudi3)
  echo "[$i $(date +%H:%M)] A30: $A | Gaudi: $G | $(lastlog decode-gaudi3)"
  echo "$A$G" | grep -qE 'CrashLoopBackOff|ErrImagePull|ImagePullBackOff|CreateContainerConfigError|Error|OOMKilled' && { echo "A pod is failing; stopping the wait."; break; }
  echo "$A" | grep -q ready=true && echo "$G" | grep -q ready=true && break
  sleep 15
done

hr "Pods"
oc get pods -n $NS -o wide | grep -v build

smoke() {  # smoke <deploy> <port>
  local d=$1 port=$2
  echo "--- $d"
  oc exec -n $NS deploy/$d -c modelserver -- python3 -c "
import json,urllib.request
print(urllib.request.urlopen('http://localhost:$port/v1/models').read().decode()[:200])
r=urllib.request.Request('http://localhost:$port/v1/completions',data=json.dumps({'model':'$MODEL','prompt':'The capital of Texas is','max_tokens':12,'temperature':0}).encode(),headers={'Content-Type':'application/json'})
print('completion:', repr(json.loads(urllib.request.urlopen(r).read())['choices'][0]['text']))" 2>&1 | tail -3
}

hr "Smoke tests"
for d in prefill-a30:8000 decode-gaudi3:8200; do
  n=${d%%:*}; p=${d##*:}
  if [ "$(oc get deploy $n -n $NS -o jsonpath='{.status.readyReplicas}')" = "1" ]; then smoke $n $p
  else
    echo "--- $n NOT READY; last 40 log lines:"; oc logs -n $NS deploy/$n -c modelserver --tail=40 2>&1 | cut -c1-220
  fi
done

hr "Versions and NIXL setup lines (must match across vendors)"
for n in prefill-a30 decode-gaudi3; do
  echo "--- $n"; oc logs -n $NS deploy/$n -c modelserver 2>/dev/null | grep -iE 'vLLM API server version|vllm version|nixl|NixlConnector|block_size|KV cache' | head -8 | cut -c1-200
done
echo "--- routing sidecar"; oc logs -n $NS deploy/decode-gaudi3 -c routing-proxy --tail=5 2>&1 | cut -c1-200
oc get events -n $NS --field-selector type=Warning --sort-by=.lastTimestamp | grep -v build | tail -8
