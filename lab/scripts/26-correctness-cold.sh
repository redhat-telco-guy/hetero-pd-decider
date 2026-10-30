#!/usr/bin/env bash
NS=hetero-pd-lab; MODEL=Qwen/Qwen2.5-7B-Instruct; DEC=${DECODE:-decode-a30}; N=${PROMPTS:-100}
DIR=$(cd "$(dirname "$0")" && pwd); PY=$(command -v python || command -v python3)
oc whoami >/dev/null 2>&1 || { echo "Cannot reach cluster; reconnect and oc login."; exit 1; }
pkill -f 'port-forward.*(8081|18200|18000)' 2>/dev/null; sleep 1
oc port-forward -n $NS svc/hetero-pd-epp 8081:80 >/dev/null 2>&1 &
oc port-forward -n $NS deploy/$DEC 18200:8200 >/dev/null 2>&1 &
oc port-forward -n $NS deploy/prefill-a30 18000:8000 >/dev/null 2>&1 &
trap 'pkill -f "port-forward.*(8081|18200|18000)" 2>/dev/null' EXIT
sleep 6
echo "cache_salt support check:"; curl -s -m 30 localhost:18200/v1/completions -H 'Content-Type: application/json' -d '{"model":"'$MODEL'","prompt":"Hello","max_tokens":2,"cache_salt":"probe"}' | head -c 200; echo
( cd "$DIR" && $PY correctness3.py --router http://localhost:8081 --decode http://localhost:18200 --prefill http://localhost:18000 --model $MODEL --prompts $N )
