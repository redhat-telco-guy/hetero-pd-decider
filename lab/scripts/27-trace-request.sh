#!/usr/bin/env bash
# Send ONE request through the router with a known x-request-id and show every hop it touched.
NS=hetero-pd-lab; MODEL=Qwen/Qwen2.5-7B-Instruct; DEC=${DECODE:-decode-a30}
oc whoami >/dev/null 2>&1 || { echo "Cannot reach cluster; reconnect and oc login."; exit 1; }
RID=trace-$(date +%H%M%S)-$RANDOM
hr() { printf '\n==== %s ====\n' "$1"; }
metric() { oc exec -n $NS deploy/$DEC -c modelserver -- python3 -c "import urllib.request;print(urllib.request.urlopen('http://localhost:8200/metrics').read().decode())" 2>/dev/null | grep -E "^$1" | awk '{s+=$NF} END{print s+0}'; }
pkill -f 'port-forward.*8081' 2>/dev/null; sleep 1
oc port-forward -n $NS svc/hetero-pd-epp 8081:80 >/dev/null 2>&1 & PF=$!; trap "kill $PF 2>/dev/null" EXIT; sleep 5
H0=$(metric vllm:external_prefix_cache_hits_total)
SINCE=$(date -u +%Y-%m-%dT%H:%M:%SZ); sleep 1
PROMPT=$(python3 -c "print('Summarize this incident log in one sentence. ' + ' '.join(f'At 10:{i%60:02d} UTC service-{i%7} in region-{i%3} returned error {500+i%4} for {i*3} seconds.' for i in range(120)))")

hr "1. Send request $RID through the router"
curl -sS -m 120 localhost:8081/v1/completions -H 'Content-Type: application/json' -H "x-request-id: $RID" \
  -d "$(python3 -c "import json,sys;print(json.dumps({'model':'$MODEL','prompt':sys.argv[1],'max_tokens':30,'temperature':0}))" "$PROMPT")" \
  -D /tmp/trace-headers.txt -o /tmp/trace-body.json -w 'HTTP %{http_code} in %{time_total}s\n'
python3 -c "import json;d=json.load(open('/tmp/trace-body.json'));print('prompt tokens:',d['usage']['prompt_tokens'],'| answer:',repr(d['choices'][0]['text'][:120]))" 2>/dev/null || head -c 300 /tmp/trace-body.json
sleep 3

hr "2. Router (EPP): what it chose for $RID"
oc logs -n $NS deploy/hetero-pd-epp -c epp --since-time=$SINCE 2>/dev/null | grep "$RID" | python3 -c "
import sys,json
for l in sys.stdin:
    try: d=json.loads(l)
    except: continue
    body=d.get('body','')
    keep={k:v for k,v in d.items() if k in ('plugin','endpointsBefore','reason','remote','remoteSeconds','localSeconds','stallSeconds','transferSeconds','prefillPod','decodePod','targetEndpoint','result','profile','endpoint','pod') }
    if any(w in body.lower() for w in ('decision','profile','picked','selected','result','header','prefill','decode','disagg')) or keep:
        print('-', body, json.dumps(keep) if keep else '')
" | head -25

hr "3. Decode pod's routing sidecar (did it call the prefill card?)"
oc logs -n $NS deploy/$DEC -c routing-proxy --since-time=$SINCE 2>/dev/null | tail -10 | cut -c1-300

hr "4. Prefill card (A30 #1): did it receive a request?"
oc logs -n $NS deploy/prefill-a30 -c modelserver --since-time=$SINCE 2>/dev/null | grep -E 'POST /v1|kv_transfer|NIXL|nixl' | tail -5 | cut -c1-250

hr "5. Decode card: did KV arrive, and did it answer?"
oc logs -n $NS deploy/$DEC -c modelserver --since-time=$SINCE 2>/dev/null | grep -E 'POST /v1|KV Transfer metrics' | tail -5 | cut -c1-250
echo "KV tokens received over NIXL for this request: $(( $(metric vllm:external_prefix_cache_hits_total) - H0 ))"
