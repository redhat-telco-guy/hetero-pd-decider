#!/usr/bin/env bash
# Deploy the A30 prefill engine now (public image), so the model download and
# warm-up overlap with the Gaudi build. Then check it answers.
set -uo pipefail
NS=hetero-pd-lab
REPO=$(cd "$(dirname "$0")/../.." && pwd); MS=$REPO/lab/modelserver
hr() { printf '\n==== %s ====\n' "$1"; }
oc whoami >/dev/null 2>&1 || { echo "Cannot reach cluster; reconnect and oc login, then re-run."; exit 1; }

hr "Service account + anyuid (vLLM images write under /root)"
oc apply -n $NS -f $MS/common/serviceaccount.yaml
oc adm policy add-scc-to-user anyuid -z hetero-pd -n $NS

hr "Deploy prefill-a30"
oc apply -n $NS -f $MS/layout-a-a30-prefill/prefill-a30.yaml

hr "Waiting for the pod (image pull ~10 GB, model download ~16 GB, then load; up to 20 min)"
for i in $(seq 1 80); do
  P=$(oc get pods -n $NS -l app=prefill-a30 -o name | head -1)
  ST=$(oc get $P -n $NS -o jsonpath='{.status.phase} ready={.status.containerStatuses[0].ready} {.status.containerStatuses[0].state.waiting.reason}' 2>/dev/null)
  LAST=$(oc logs $P -n $NS --tail=1 2>/dev/null | cut -c1-140)
  echo "[$i $(date +%H:%M)] $ST | $LAST"
  echo "$ST" | grep -q 'ready=true' && break
  echo "$ST" | grep -qE 'CrashLoopBackOff|ErrImagePull|ImagePullBackOff|CreateContainerConfigError' && break
  oc logs $P -n $NS 2>/dev/null | grep -qiE '401|gated repo|Access to model .* is restricted' && { echo "Hugging Face refused the download (license not accepted or bad token)."; break; }
  sleep 15
done

hr "Result"
oc get pods -n $NS -o wide
P=$(oc get pods -n $NS -l app=prefill-a30 -o name | head -1)
if oc get $P -n $NS -o jsonpath='{.status.containerStatuses[0].ready}' | grep -q true; then
  echo "--- /v1/models"
  oc exec -n $NS $P -- python3 -c "import urllib.request;print(urllib.request.urlopen('http://localhost:8000/v1/models').read().decode())"
  echo "--- test completion"
  oc exec -n $NS $P -- python3 -c "
import json,urllib.request
r=urllib.request.Request('http://localhost:8000/v1/completions',data=json.dumps({'model':'Qwen/Qwen2.5-7B-Instruct','prompt':'The capital of Texas is','max_tokens':12,'temperature':0}).encode(),headers={'Content-Type':'application/json'})
print(json.loads(urllib.request.urlopen(r).read())['choices'][0]['text'])"
  echo "--- NIXL / KV lines from startup"
  oc logs $P -n $NS | grep -iE 'nixl|kv_transfer|KV cache|block_size|version' | head -15 | cut -c1-220
  echo "A30 PREFILL: READY"
else
  echo "A30 PREFILL: NOT READY. Last 40 log lines:"
  oc logs $P -n $NS --tail=40 2>&1 | cut -c1-220
  oc get events -n $NS --field-selector type=Warning --sort-by=.lastTimestamp | tail -10
fi

hr "Gaudi build progress"
oc get build vllm-gaudi-nixl-1 -n $NS
oc logs bc/vllm-gaudi-nixl -n $NS --tail=5 2>&1 | cut -c1-200
