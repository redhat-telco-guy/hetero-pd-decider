#!/usr/bin/env bash
# Gaudi temperature watchdog. Reads every Gaudi's chip temperature every 10 s from the Habana metric
# exporter. At LIMIT (default 80 C; shutdown is 90 C and a card rose 25 C in under a minute on Oct 29) it stops every Gaudi model server (scale to 0)
# and stops any dashboard traffic, so a card can never reach its shutdown temperature.
#   bash lab/mixed/42-gaudi-watchdog.sh [minutes] [limit]      (0 minutes = run until Ctrl-C)
# Every reading is appended to gaudi-temps.csv (time, serial, chip C, board C, power W, busy %).
set -uo pipefail
MIN=${1:-0}; LIMIT=${2:-80}; EVERY=${EVERY:-3}; NS=hetero-pd-lab; HNS=habana-ai-operator
REPO=$(cd "$(dirname "$0")/../.." && pwd); CSV=$REPO/gaudi-temps.csv
[ -f $CSV ] || echo "time,serial,chip_c,board_c,power_w,util_pct" > $CSV
P=$(oc get pods -n $HNS -o name | grep metric-exporter | head -1 | sed 's#pod/##')
PORT=$(oc get pod $P -n $HNS -o jsonpath='{.spec.containers[0].ports[0].containerPort}')
[ -n "$P" ] && [ -n "$PORT" ] || { echo "WATCHDOG: no Gaudi metric exporter found"; exit 1; }
stop_all() {
  # NOSTOP=1: display only; the in-cluster watchdog (45-watchdog-incluster.sh) does the stopping.
  [ "${NOSTOP:-0}" = 1 ] && { echo "WATCHDOG (display) $(date +%H:%M:%S): $1; the in-cluster watchdog acts on this"; return; }
  echo "WATCHDOG $(date +%H:%M:%S): $1 -> stopping Gaudi model servers and traffic"
  for d in $(oc get deploy -n $NS -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.template.spec.containers[*].resources.limits}{"\n"}{end}' | grep habana | cut -d' ' -f1); do
    oc scale deploy/$d -n $NS --replicas=0 && echo "  scaled $d to 0"; done
  oc exec -n $NS deploy/hetero-pd-dashboard -- python3 -c "import urllib.request as u;u.urlopen(u.Request('http://localhost:8080/api/traffic/stop',data=b'{}',headers={'Content-Type':'application/json'}))" >/dev/null 2>&1 && echo "  dashboard traffic stopped"
}
END=$(( $(date +%s) + MIN * 60 )); MAXT=0; FAILS=0; LASTOK=$(date +%s); T=0
echo "WATCHDOG started $(date +%H:%M:%S): limit ${LIMIT} C, readings every ${EVERY} s, log $CSV"
while :; do
  M=$(oc get --raw "/api/v1/namespaces/$HNS/pods/$P:$PORT/proxy/metrics" --request-timeout=4s 2>/dev/null)
  if [ -z "$M" ]; then FAILS=$((FAILS+1)); GAP=$(( $(date +%s) - LASTOK )); echo "WATCHDOG: no reading for ${GAP} s"
    # The exporter pod can be replaced (e.g. after an interval change): look it up again.
    P=$(oc get pods -n $HNS -o name 2>/dev/null | grep metric-exporter | head -1 | sed 's#pod/##')
    # Fail safe: stop if blind for 60 s, or for 30 s when the last reading was within 10 C of the limit.
    if [ $GAP -ge 60 ] || { [ $GAP -ge 30 ] && [ "${T:-0}" -ge $((LIMIT - 10)) ]; }; then stop_all "no temperature reading for ${GAP} s (last ${T:-?} C)"; [ "${NOSTOP:-0}" = 1 ] || exit 2; fi
    sleep $EVERY; continue; fi
  FAILS=0; LASTOK=$(date +%s)
  LINE=$(echo "$M" | python3 -c "
import sys,re,time
v={}
for l in sys.stdin:
    m=re.match(r'(habanalabs_temperature_onchip|habanalabs_temperature_onboard|habanalabs_power_mW|habanalabs_utilization)\{.*Serial=\"([^\"]+)\".*\} (\S+)',l)
    if m: v.setdefault(m.group(2),{})[m.group(1)]=float(m.group(3))
t=time.strftime('%H:%M:%S'); out=[]; mx=0
with open('$CSV','a') as f:
    for s,d in sorted(v.items()):
        c=d.get('habanalabs_temperature_onchip',0); b=d.get('habanalabs_temperature_onboard',0); p=d.get('habanalabs_power_mW',0)/1000; u=d.get('habanalabs_utilization',0)
        f.write(f'{t},{s},{c:.0f},{b:.0f},{p:.0f},{u:.0f}\n'); out.append(f'{s} {c:.0f}C/{b:.0f}C {p:.0f}W {u:.0f}%'); mx=max(mx,c,b)
print(f'{mx:.0f}|'+'   '.join(out))")
  T=${LINE%%|*}; [ "$T" -gt "$MAXT" ] 2>/dev/null && MAXT=$T
  echo "$(date +%H:%M:%S)  ${LINE#*|}   (max so far ${MAXT} C)"
  [ "$T" -ge "$LIMIT" ] 2>/dev/null && { stop_all "a Gaudi reached ${T} C"; [ "${NOSTOP:-0}" = 1 ] || exit 3; }
  [ $MIN -gt 0 ] && [ $(date +%s) -ge $END ] && { echo "WATCHDOG done: hottest reading ${MAXT} C (limit ${LIMIT} C)"; exit 0; }
  sleep $EVERY
done
