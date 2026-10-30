#!/usr/bin/env bash
# 15-minute Gaudi burn-in: realistic traffic through the router while the watchdog prints every card's
# temperature. Stops everything at 85 C. Pass: the hottest reading stays below 85 C.
#   bash lab/mixed/43-burn-in.sh [minutes] 2>&1 | tee 43-burn-in.txt
set -uo pipefail
MIN=${1:-15}; A=$(cd "$(dirname "$0")" && pwd); REPO=$(cd "$A/../.." && pwd); NS=hetero-pd-lab
oc whoami >/dev/null 2>&1 || { echo "Not logged in. Run oc login first."; exit 1; }
echo "==== Start $MIN min of traffic: 32 chat users + 0.5 documents/s of ~2,000 tokens"
oc exec -n $NS deploy/hetero-pd-dashboard -- python3 -c "
import json,urllib.request as u
r=u.Request('http://localhost:8080/api/traffic/start',data=json.dumps({'users':32,'docsPerSec':0.5,'minutes':$MIN,'chatTokens':250,'docTokens':2000}).encode(),headers={'Content-Type':'application/json'})
print(u.urlopen(r).read().decode())"
echo "==== Gaudi temperatures every 3 s (limit 80 C; shutdown is 90 C)"
bash $A/42-gaudi-watchdog.sh $MIN 80; RC=$?
echo "==== Traffic result"
oc exec -n $NS deploy/hetero-pd-dashboard -- python3 -c "
import json,urllib.request as u
s=json.load(u.urlopen('http://localhost:8080/api/state')); t=s.get('trafficTotal') or {}
print({k:t.get(k) for k in ['chatDone','docDone','errors','tokensPerSec','chatTtftP95','docTtftP50']})"
[ $RC = 0 ] && echo "BURN-IN PASSED: hottest reading stayed below 80 C" || echo "BURN-IN STOPPED by the watchdog (see above). Send gaudi-temps.csv to the lab owner."
