#!/usr/bin/env bash
# One request through the router, then every hop's logs for it.
NS=hetero-pd-lab; MODEL=Qwen/Qwen2.5-7B-Instruct
hr() { printf '\n==== %s ====\n' "$1"; }
oc whoami >/dev/null 2>&1 || { echo "Cannot reach cluster"; exit 1; }
pkill -f 'port-forward.*8081' 2>/dev/null; sleep 1
oc port-forward -n $NS svc/hetero-pd-epp 8081:80 >/dev/null 2>&1 & PF=$!; trap "kill $PF 2>/dev/null" EXIT; sleep 5
SINCE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
BODY='{"model":"'$MODEL'","prompt":"'"$(python3 -c 'print(("The quick brown fox jumps over the lazy dog. "*60).strip())' 2>/dev/null || python -c 'print(("The quick brown fox jumps over the lazy dog. "*60).strip())')"'","max_tokens":16,"temperature":0}'

hr "Non-streaming request via router"
curl -sS -m 120 -o /tmp/r1.txt -w 'HTTP %{http_code} in %{time_total}s\n' localhost:8081/v1/completions -H 'Content-Type: application/json' -d "$BODY"; head -c 600 /tmp/r1.txt; echo
hr "Streaming request via router"
curl -sS -m 120 -N localhost:8081/v1/completions -H 'Content-Type: application/json' -d "${BODY%\}},\"stream\":true}" -w '\nHTTP %{http_code}\n' | head -c 800; echo
sleep 3

hr "Router (EPP) logs for these requests"
oc logs -n $NS deploy/hetero-pd-epp -c epp --since-time=$SINCE 2>/dev/null | grep -viE 'metrics|refresh|poll' | tail -25 | cut -c1-400
hr "Router proxy (envoy) logs"
for c in $(oc get deploy hetero-pd-epp -n $NS -o jsonpath='{.spec.template.spec.containers[*].name}'); do
  [ "$c" = epp ] && continue; echo "-- $c"; oc logs -n $NS deploy/hetero-pd-epp -c $c --since-time=$SINCE 2>/dev/null | tail -8 | cut -c1-400
done
hr "Gaudi routing sidecar"
oc logs -n $NS deploy/decode-gaudi3 -c routing-proxy --since-time=$SINCE 2>/dev/null | tail -20 | cut -c1-400
hr "A30 prefill engine"
oc logs -n $NS deploy/prefill-a30 -c modelserver --since-time=$SINCE 2>/dev/null | grep -vE 'GET /metrics|Avg prompt' | tail -20 | cut -c1-300
hr "Gaudi decode engine"
oc logs -n $NS deploy/decode-gaudi3 -c modelserver --since-time=$SINCE 2>/dev/null | grep -vE 'GET /metrics|Avg prompt' | tail -25 | cut -c1-300
hr "Pods / endpoints the router sees"
oc get pods -n $NS -l llm-d.ai/guide=hetero-pd -L llm-d.ai/role -o wide
oc get svc -n $NS
