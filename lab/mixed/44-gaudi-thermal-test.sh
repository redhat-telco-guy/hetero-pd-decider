#!/usr/bin/env bash
# Gaudi thermal test with full logs. Both Gaudi cards serve answers, traffic rises in steps
# (2, 4, 8, 16 chat users, 3 min each). The in-cluster watchdog is the only reader of the Gaudi
# metric exporter (it rate-limits readers): it logs every card every 3 s and stops the Gaudis at 80 C
# or after 30 s without a reading. This laptop only shows that log, so a dropped connection is harmless.
# Output folder: thermal-test-<date-time>/  (send it to the lab owner)
#   bash lab/mixed/44-gaudi-thermal-test.sh 2>&1 | tee thermal-test.txt
set -uo pipefail
A=$(cd "$(dirname "$0")" && pwd); REPO=$(cd "$A/../.." && pwd); NS=hetero-pd-lab; HNS=habana-ai-operator
STEPS=${STEPS:-"2 4 8 16"}; STEP_MIN=${STEP_MIN:-3}; LIMIT=${LIMIT:-80}
OUT=$REPO/thermal-test-$(date +%Y%m%d-%H%M); mkdir -p $OUT
hr() { printf '\n==== %s ====\n' "$1"; }
mark() { echo "$(date -u +%H:%M:%S),$1" >> $OUT/phases.csv; }   # UTC, like the watchdog pod's clock
oc whoami >/dev/null 2>&1 || { echo "Not logged in. Run oc login first."; exit 1; }
GNODE=$(oc get nodes -l feature.node.kubernetes.io/pci-1da3.present=true -o jsonpath='{.items[0].metadata.name}')
[ -f $REPO/.watchdog.pid ] && kill $(cat $REPO/.watchdog.pid) 2>/dev/null; rm -f $REPO/.watchdog.pid; pkill -f 42-gaudi-watchdog.sh 2>/dev/null
echo "time,phase" > $OUT/phases.csv
gstopped() { [ "$(oc get deploy decode-gaudi3 -n $NS -o jsonpath='{.spec.replicas}' 2>/dev/null)" = 0 ]; }
show() {  # show <seconds>: print the watchdog's readings live for that long (one line per reading round)
  oc logs -n $NS deploy/gaudi-watchdog -f --since=5s 2>/dev/null | python3 -u -c "
import sys
row={}
for l in sys.stdin:
    if l.startswith('csv,time'): continue
    if l.startswith('csv,'):
        _,t,s,c,b,p,u=l.strip().split(',')
        if s in row: print(t,'UTC  ','   '.join(f'{k} {v}' for k,v in sorted(row.items())),flush=True); row={}
        row[s]=f'{c}C/{b}C {p}W'
    else: print(l.rstrip(),flush=True)" &
  local P=$!; sleep $1; kill $P 2>/dev/null; pkill -f "oc logs -n $NS deploy/gaudi-watchdog -f" 2>/dev/null; wait $P 2>/dev/null; }

hr "0. Gaudi metric exporter every 2 s; in-cluster watchdog (the only reader)"
CUR=$(oc get clusterpolicies.habanalabs.habana.ai -o jsonpath='{.items[0].spec.metric_exporter.interval}')
[ "$CUR" != 2 ] && oc patch clusterpolicies.habanalabs.habana.ai $(oc get clusterpolicies.habanalabs.habana.ai -o jsonpath='{.items[0].metadata.name}') --type merge -p '{"spec":{"metric_exporter":{"interval":2}}}' >/dev/null
bash $A/45-watchdog-incluster.sh $LIMIT >/dev/null 2>&1
oc get deploy gaudi-watchdog -n $NS -o jsonpath='{.status.readyReplicas}' | grep -q 1 || { echo "In-cluster watchdog not running; stopping."; exit 1; }
echo "  watchdog running: limit $LIMIT C, readings every 3 s"

hr "1. Which card is in which slot, kernel log before the test"
oc logs -n $HNS $(oc get pods -n $HNS -o name | grep device-plugin | head -1) 2>/dev/null | grep -o '"serial":"[^"]*".*"pci_bus_id":"[^"]*"' | sed -E 's/"serial":"([^"]*)".*"pci_bus_id":"([^"]*)"/  serial \1 -> slot \2/' | sort -u | tee $OUT/card-slots.txt
oc debug node/$GNODE -q -- chroot /host sh -c 'date -u; dmesg -T | grep -i habanalabs' > $OUT/dmesg-before.txt 2>&1

hr "2. Idle baseline, 1 min"
mark idle; show 60 | awk 'NR%5==1'

hr "3. A Gaudi model server on each card (2 replicas), warm-up"
mark warmup; oc scale deploy/decode-gaudi3 -n $NS --replicas=2 >/dev/null
for i in $(seq 1 45); do
  r=$(oc get deploy decode-gaudi3 -n $NS -o jsonpath='{.status.readyReplicas}')
  echo "  [$(date +%H:%M)] ready ${r:-0}/2 | $(oc logs -n $NS deploy/gaudi-watchdog --tail=2 2>/dev/null | grep '^csv,[0-9]' | cut -d, -f2-5 | tr '\n' ' ')"
  gstopped && { echo "  the watchdog stopped the Gaudis during warm-up:"; oc logs -n $NS deploy/gaudi-watchdog --tail=100 | grep -A3 stopping | tail -4; break; }
  [ "${r:-0}" -ge 2 ] && break; sleep 40
done
oc get pods -n $NS -l app=decode-gaudi3 --no-headers 2>/dev/null | awk '{print "  "$1, $2, $3}'

hr "4. Load steps: $STEPS chat users, $STEP_MIN min each (watchdog stops at $LIMIT C)"
if ! gstopped && [ "$(oc get deploy decode-gaudi3 -n $NS -o jsonpath='{.status.readyReplicas}')" -ge 1 ] 2>/dev/null; then
  for u in $STEPS; do
    mark "load-${u}-users"; echo "-- $u chat users, $STEP_MIN min"
    oc exec -n $NS deploy/hetero-pd-dashboard -- python3 -c "
import json,urllib.request as r
r.urlopen(r.Request('http://localhost:8080/api/traffic/start',data=json.dumps({'users':$u,'docsPerSec':0,'minutes':$STEP_MIN,'chatTokens':250,'docTokens':700}).encode(),headers={'Content-Type':'application/json'}))" >/dev/null 2>&1
    show $((STEP_MIN * 60)) | awk 'NR%6==1 || /WATCHDOG|scaled|stopped/'
    oc exec -n $NS deploy/hetero-pd-dashboard -- python3 -c "
import json,urllib.request as r; t=json.load(r.urlopen('http://localhost:8080/api/state')).get('trafficTotal') or {}
print('   served:', t.get('chatDone'), 'replies,', t.get('errors'), 'errors,', round(t.get('tokensPerSec') or 0), 'tok/s')" 2>/dev/null
    gstopped && { echo "   the watchdog stopped the Gaudis at this step"; break; }
    sleep 15
  done
else echo "  skipped: no Gaudi model server running"; fi
oc exec -n $NS deploy/hetero-pd-dashboard -- python3 -c "import urllib.request as r;r.urlopen(r.Request('http://localhost:8080/api/traffic/stop',data=b'{}',headers={'Content-Type':'application/json'}))" >/dev/null 2>&1

hr "5. Cool-down with the Gaudi servers stopped, 3 min"
oc scale deploy/decode-gaudi3 -n $NS --replicas=0 >/dev/null; mark cooldown; show 180 | awk 'NR%10==1'; mark end

hr "6. New Gaudi kernel messages during the test"
oc debug node/$GNODE -q -- chroot /host sh -c 'date -u; dmesg -T | grep -i habanalabs' > $OUT/dmesg-after.txt 2>&1
diff <(sort -u $OUT/dmesg-before.txt) <(sort -u $OUT/dmesg-after.txt) | grep '^>' | grep -v ' UTC 20' | sed 's/^> /  /' | tee $OUT/dmesg-new.txt | tail -20
[ -s $OUT/dmesg-new.txt ] || echo "  none"

hr "7. Summary per phase and card"
oc logs -n $NS deploy/gaudi-watchdog --since=3h > $OUT/incluster-watchdog.log 2>&1
{ echo "time,serial,chip_c,board_c,power_w,util_pct"; grep '^csv,[0-9]' $OUT/incluster-watchdog.log | cut -d, -f2-; } > $OUT/all-readings.csv
python3 - $OUT <<'PY' | tee $OUT/summary.txt
import csv, sys, os
out = sys.argv[1]
ph = list(csv.DictReader(open(os.path.join(out, 'phases.csv'))))
rows = [r for r in csv.DictReader(open(os.path.join(out, 'all-readings.csv'))) if ph[0]['time'] <= r['time'] <= ph[-1]['time']]
def phase(t):
    p = None
    for x in ph:
        if x['time'] <= t: p = x['phase']
    return p
agg = {}
for r in rows:
    a = agg.setdefault((phase(r['time']), r['serial']), {'n': 0, 'max': 0, 'pw': 0, 'last': 0})
    c = max(float(r['chip_c']), float(r['board_c'])); a['n'] += 1; a['max'] = max(a['max'], c); a['pw'] = max(a['pw'], float(r['power_w'])); a['last'] = c
print(f"{'phase':<16}{'card':<13}{'readings':>9}{'max C':>8}{'end C':>8}{'max W':>8}")
for x in ph[:-1]:
    for (p, s), a in sorted(agg.items()):
        if p == x['phase']: print(f"{p:<16}{s:<13}{a['n']:>9}{a['max']:>8.0f}{a['last']:>8.0f}{a['pw']:>8.0f}")
PY
grep -h 'WATCHDOG.*stopping' $OUT/incluster-watchdog.log | tail -3
echo; echo "All logs in: $OUT"
