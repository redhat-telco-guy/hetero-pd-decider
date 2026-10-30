#!/usr/bin/env bash
# Runbook step 4: install the router with every request forced through A30 prefill -> Gaudi decode,
# then compare output against Gaudi-only. Pass = identical 64-token output on >= 95% of prompts.
set -uo pipefail
NS=hetero-pd-lab; MODEL=Qwen/Qwen2.5-7B-Instruct; PROMPTS=${PROMPTS:-200}; DEC=${DECODE:-decode-gaudi3}
REPO=$(cd "$(dirname "$0")/../.." && pwd); KIT=$REPO/lab
CH=$REPO/.cache/llm-d; PY=$(command -v python || command -v python3)
hr() { printf '\n==== %s ====\n' "$1"; }
oc whoami >/dev/null 2>&1 || { echo "Cannot reach cluster; reconnect and oc login, then re-run."; exit 1; }

hr "Engines ready?"
for d in prefill-a30 $DEC; do
  r=$(oc get deploy $d -n $NS -o jsonpath='{.status.readyReplicas}'); echo "$d ready=${r:-0}"
  [ "${r:-0}" -ge 1 ] || { echo "$d not ready yet; wait for 10-deploy-layout-a.sh to finish, then re-run."; exit 1; }
done

hr "Router chart at the plugin's llm-d commit"
BASE=$(tr -d '[:space:]' < "$REPO/plugin/llm-d-patch/BASE_COMMIT")
[ -d "$CH/.git" ] || git clone -q https://github.com/llm-d/llm-d-inference-scheduler.git "$CH"
git -C "$CH" fetch -q origin 2>/dev/null; git -C "$CH" checkout -q "$BASE" && echo "chart source at $BASE"
CHART=$CH/config/charts/llm-d-router-standalone
helm dependency build "$CHART" >/dev/null 2>&1 || helm dependency update "$CHART"

hr "Install router (always-disaggregate) as release hetero-pd"
helm upgrade --install hetero-pd "$CHART" -n $NS \
  -f $KIT/router/common.values.yaml -f $KIT/router/always.values.yaml $( [ -f $KIT/router/site.values.yaml ] && echo -f $KIT/router/site.values.yaml ) --wait --timeout 5m
oc get deploy,svc,pods -n $NS -l app.kubernetes.io/instance=hetero-pd 2>/dev/null || oc get deploy,svc -n $NS
EPP=$(oc get deploy -n $NS -o name | grep -E 'epp|router' | grep -v -E 'prefill|decode' | head -1)
SVC=$(oc get svc -n $NS -o name | grep -E 'epp|router|hetero-pd' | grep -v -E 'prefill|decode' | head -1)
echo "router deployment: $EPP   service: $SVC"
oc logs -n $NS $EPP --all-containers --tail=200 2>/dev/null | grep -iE 'plugin|always-disagg|error|endpoint' | tail -12 | cut -c1-220

hr "Port-forwards"
pkill -f 'port-forward.*(8081|18200)' 2>/dev/null; sleep 1
oc port-forward -n $NS $SVC 8081:80 >/tmp/pf-router.log 2>&1 &
oc port-forward -n $NS deploy/$DEC 18200:8200 >/tmp/pf-gaudi.log 2>&1 &
trap 'pkill -f "port-forward.*(8081|18200)" 2>/dev/null' EXIT
sleep 6
curl -s -m 10 localhost:8081/v1/models | head -c 200; echo
curl -s -m 10 localhost:18200/v1/models | head -c 200; echo

hr "Prefix-cache hits on Gaudi before"
HB=$(oc exec -n $NS deploy/$DEC -c modelserver -- python3 -c "import urllib.request;print(urllib.request.urlopen('http://localhost:8200/metrics').read().decode())" 2>/dev/null | grep -E '^vllm:external_prefix_cache_hits_total' | awk '{s+=$NF} END{print s+0}')
echo "external_prefix_cache_hits_total=$HB"

hr "Correctness: $PROMPTS prompts, router (A30 prefill -> $DEC) vs $DEC alone"
$PY -c "import requests" 2>/dev/null || $PY -m pip install -q -r $KIT/scripts/requirements.txt
( cd $KIT/scripts && $PY correctness.py --router http://localhost:8081 --reference http://localhost:18200 --model $MODEL --prompts $PROMPTS )
RC=$?

hr "Evidence the KV actually crossed vendors"
HA=$(oc exec -n $NS deploy/$DEC -c modelserver -- python3 -c "import urllib.request;print(urllib.request.urlopen('http://localhost:8200/metrics').read().decode())" 2>/dev/null | grep -E '^vllm:external_prefix_cache_hits_total' | awk '{s+=$NF} END{print s+0}')
echo "external_prefix_cache_hits_total: before=$HB after=$HA  (must rise)"
echo "--- Gaudi NIXL log lines"; oc logs -n $NS deploy/$DEC -c modelserver --since=30m | grep -iE 'nixl|remote|kv transfer|handshake' | tail -10 | cut -c1-220
echo "--- A30 NIXL log lines";   oc logs -n $NS deploy/prefill-a30   -c modelserver --since=30m | grep -iE 'nixl|remote|kv transfer|handshake' | tail -10 | cut -c1-220
echo "--- sidecar";              oc logs -n $NS deploy/$DEC -c routing-proxy --since=30m | grep -iE 'prefill|error' | tail -5 | cut -c1-220
[ $RC -eq 0 ] && echo "CORRECTNESS GATE: PASS" || echo "CORRECTNESS GATE: FAIL (rc=$RC)"
