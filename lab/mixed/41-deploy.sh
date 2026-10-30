#!/usr/bin/env bash
# Mixed lab, part 2: model servers (A30 reads prompts, Gaudi 3 writes answers), router with your plugin
# (auto is the default) and the dashboard. The Gaudi watchdog runs in the background the whole time,
# because the Gaudi warm-up (graph compilation) already works the card hard.
#   bash lab/mixed/41-deploy.sh 2>&1 | tee 41-deploy.txt
set -uo pipefail
A=$(cd "$(dirname "$0")" && pwd); REPO=$(cd "$A/../.." && pwd); NS=hetero-pd-lab
hr() { printf '\n==== %s ====\n' "$1"; }
oc whoami >/dev/null 2>&1 || { echo "Not logged in. Run oc login first."; exit 1; }
oc get istag vllm-gaudi-nixl:v0.26.0-tfpin -n $NS >/dev/null 2>&1 && oc get istag llm-d-router-endpoint-picker:hetero-pd-dev -n $NS >/dev/null 2>&1 \
  || { echo "Images not built yet; run lab/mixed/40-build-images.sh first."; exit 1; }

hr "1. Start the Gaudi watchdog in the background (log: gaudi-watchdog.log, readings: gaudi-temps.csv)"
if [ -f $REPO/.watchdog.pid ] && kill -0 $(cat $REPO/.watchdog.pid) 2>/dev/null; then echo "  already running (pid $(cat $REPO/.watchdog.pid))"
else nohup bash $A/42-gaudi-watchdog.sh 0 80 > $REPO/gaudi-watchdog.log 2>&1 & echo $! > $REPO/.watchdog.pid; sleep 12; tail -2 $REPO/gaudi-watchdog.log; fi
echo "  stop it later with: kill \$(cat ~/hetero-pd-decider/.watchdog.pid)"

hr "2. Model servers: prefill-a30 (reads) + decode-gaudi3 (answers), 1 Gaudi for the first test"
oc apply -n $NS -k $REPO/lab/modelserver/layout-a-a30-prefill
oc scale deploy/decode-gaudi3 -n $NS --replicas=1 >/dev/null
for i in $(seq 1 150); do
  p=$(oc get deploy prefill-a30 -n $NS -o jsonpath='{.status.readyReplicas}'); g=$(oc get deploy decode-gaudi3 -n $NS -o jsonpath='{.status.readyReplicas}')
  r=$(oc get deploy decode-gaudi3 -n $NS -o jsonpath='{.spec.replicas}')
  [ "${r:-1}" = 0 ] && { echo "  decode-gaudi3 was stopped (the watchdog tripped?). See gaudi-watchdog.log"; tail -5 $REPO/gaudi-watchdog.log; exit 1; }
  L=$(oc logs -n $NS deploy/decode-gaudi3 -c modelserver --tail=1 2>/dev/null | tr '\r' '\n' | tail -1 | cut -c1-90)
  echo "  [$i $(date +%H:%M)] prefill-a30 ready=${p:-0}  decode-gaudi3 ready=${g:-0} | $L | $(tail -1 $REPO/gaudi-watchdog.log | cut -c1-60)"
  [ "${p:-0}" -ge 1 ] && [ "${g:-0}" -ge 1 ] && break
  oc get pods -n $NS -l llm-d.ai/guide=hetero-pd --no-headers | grep -qE 'CrashLoop|ImagePull|Error' && { oc get pods -n $NS -o wide | grep -v build; oc logs -n $NS deploy/decode-gaudi3 -c modelserver --tail=40; exit 1; }
  sleep 20
done

hr "3. Router with your plugin (auto) + stock and always-move configs"
bash $REPO/lab/a30-only/06-router.sh 2>&1 | tail -4

hr "4. Dashboard (old results loaded for comparison)"
bash $REPO/lab/a30-only/07-dashboard.sh 2>&1 | tail -4
H=$(ls -d $REPO/lab-archive/*/results/history.json 2>/dev/null | tail -1)
[ -n "$H" ] && bash $REPO/lab/scripts/35-restore-history.sh $H --merge 2>&1 | grep -E 'history now|rolled out'

hr "5. Smoke test through the router: one short and one long request"
oc exec -n $NS deploy/hetero-pd-dashboard -- python3 -c "
import json,urllib.request,time
for n,p in [('short','The capital of Texas is'),('long','Summarize: '+'The service reported elevated latency. '*300)]:
    t=time.time(); r=urllib.request.Request('http://hetero-pd-epp.$NS.svc/v1/completions',data=json.dumps({'model':'Qwen/Qwen2.5-7B-Instruct','prompt':p,'max_tokens':16,'temperature':0}).encode(),headers={'Content-Type':'application/json'})
    out=json.loads(urllib.request.urlopen(r,timeout=120).read())
    print(f'  {n}: {out[\"usage\"][\"prompt_tokens\"]} prompt tokens, {time.time()-t:.2f} s ->', repr(out['choices'][0]['text'][:60]))"
oc logs -n $NS deploy/hetero-pd-epp -c epp --tail=200 2>/dev/null | grep 'hetero-pd-decider decision' | tail -2 | python3 -c "
import sys,json
for l in sys.stdin:
    j=json.loads(l); print('  plugin decided:', 'MOVE' if j['remote'] else 'KEEP', '| reason', j['reason'], '| strategy', j.get('strategy'), '| uncached', j['uncachedTokens'])"
hr "Watchdog"
tail -3 $REPO/gaudi-watchdog.log
echo; echo "Next: bash lab/mixed/43-burn-in.sh 2>&1 | tee 43-burn-in.txt   (15 min of load with the watchdog watching)"
