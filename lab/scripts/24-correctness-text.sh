#!/usr/bin/env bash
# Correctness with realistic prompts and a card-to-card baseline. Router must already be installed (always split).
NS=hetero-pd-lab; MODEL=Qwen/Qwen2.5-7B-Instruct; DEC=${DECODE:-decode-a30}; N=${PROMPTS:-150}
DIR=$(cd "$(dirname "$0")" && pwd); PY=$(command -v python || command -v python3)
oc whoami >/dev/null 2>&1 || { echo "Cannot reach cluster; reconnect and oc login."; exit 1; }
pkill -f 'port-forward.*(8081|18200|18000)' 2>/dev/null; sleep 1
oc port-forward -n $NS svc/hetero-pd-epp 8081:80 >/dev/null 2>&1 &
oc port-forward -n $NS deploy/$DEC 18200:8200 >/dev/null 2>&1 &
oc port-forward -n $NS deploy/prefill-a30 18000:8000 >/dev/null 2>&1 &
trap 'pkill -f "port-forward.*(8081|18200|18000)" 2>/dev/null' EXIT
sleep 6
hits() { oc exec -n $NS deploy/$DEC -c modelserver -- python3 -c "import urllib.request;print(urllib.request.urlopen('http://localhost:8200/metrics').read().decode())" 2>/dev/null | grep -E '^vllm:external_prefix_cache_hits_total' | awk '{s+=$NF} END{print s+0}'; }
B=$(hits)
( cd "$DIR" && $PY correctness2.py --router http://localhost:8081 --decode http://localhost:18200 --prefill http://localhost:18000 --model $MODEL --prompts $N )
RC=$?
echo "external prefix-cache hits on $DEC: before=$B after=$(hits)  (rise = KV arrived over NIXL)"
exit $RC
