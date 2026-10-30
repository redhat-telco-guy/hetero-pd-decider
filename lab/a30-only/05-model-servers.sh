#!/usr/bin/env bash
# Two vLLM servers on two A30s: prefill-a30 reads prompts, decode-a30 (behind the routing sidecar) answers.
# First start pulls ~10 GB of image and ~16 GB of model weights.
source "$(dirname "$0")/lib.sh"; login
hr "Deploy prefill-a30 and decode-a30 (model $MODEL)"
# Workaround: a rolling update needs a third GPU and deadlocks with two; use Recreate.
oc kustomize $REPO/lab/modelserver/layout-d-a30-pair | sed "s#Qwen/Qwen2.5-7B-Instruct#$MODEL#; s#NVIDIA-A30#$A30_PRODUCT#" \
  | python3 -c "import sys; print(sys.stdin.read().replace('\n  replicas: 1\n', '\n  replicas: 1\n  strategy: {type: Recreate}\n'))" | oc apply -n $NS -f -
hr "Waiting for both to be ready (up to 25 min)"
for i in $(seq 1 100); do
  p=$(oc get deploy prefill-a30 -n $NS -o jsonpath='{.status.readyReplicas}'); d=$(oc get deploy decode-a30 -n $NS -o jsonpath='{.status.readyReplicas}')
  echo "  [$i $(date +%H:%M)] prefill-a30 ready=${p:-0}  decode-a30 ready=${d:-0}"
  [ "${p:-0}" -ge 1 ] && [ "${d:-0}" -ge 1 ] && break
  oc get pods -n $NS -l llm-d.ai/guide=hetero-pd --no-headers | grep -E 'CrashLoop|ImagePull|Error' && die "A model server failed; see: oc logs -n $NS deploy/decode-a30 -c modelserver"
  oc logs -n $NS deploy/prefill-a30 --tail=50 2>/dev/null | grep -qiE '401|gated repo' && die "Hugging Face refused the download (token or license)."
  sleep 15
done
oc get pods -n $NS -o wide | grep -E 'NAME|a30'
hr "Smoke test on the prefill server"
oc exec -n $NS deploy/prefill-a30 -- python3 -c "
import json,urllib.request
r=urllib.request.Request('http://localhost:8000/v1/completions',data=json.dumps({'model':'$MODEL','prompt':'The capital of Texas is','max_tokens':8,'temperature':0}).encode(),headers={'Content-Type':'application/json'})
print('  answer:',json.loads(urllib.request.urlopen(r).read())['choices'][0]['text'].strip())"
