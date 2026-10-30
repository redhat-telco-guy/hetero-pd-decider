#!/usr/bin/env bash
# Install the live hardware panel: hw-monitor on every worker (read-only) + dashboard update (Stack tab).
#   bash lab/hwmon/53-hw-monitor.sh 2>&1 | tee 53-hw-monitor.txt
set -uo pipefail
NS=hetero-pd-lab; HERE=$(cd "$(dirname "$0")" && pwd); D=$HERE/../dashboard2
oc whoami >/dev/null 2>&1 || { echo "Not logged in. Run oc login first."; exit 1; }
echo "==== 1. hw-monitor on each worker"
oc create configmap hw-monitor -n $NS --from-file=collector.py=$HERE/collector.py --dry-run=client -o yaml | oc apply -f -
oc apply -n $NS -f $HERE/hw-monitor.yaml
oc adm policy add-scc-to-user privileged -z hw-monitor -n $NS >/dev/null
oc rollout restart ds/hw-monitor -n $NS >/dev/null 2>&1
oc rollout status ds/hw-monitor -n $NS --timeout=6m || { oc get pods -n $NS -l app=hw-monitor -o wide; oc logs -n $NS -l app=hw-monitor --tail=20; exit 1; }
echo "==== 2. Dashboard (Stack tab gets the live hardware panel)"
oc apply -n $NS -f $D/dashboard.yaml >/dev/null
bash $D/update-page.sh
sleep 20
echo "==== 3. Check"
oc exec -n $NS deploy/hetero-pd-dashboard -- python3 -c "
import json,urllib.request
j=json.load(urllib.request.urlopen('http://localhost:8080/api/hw'))
for n in j['nodes']:
    print(n['node'].split('.')[0], '| fans:', len(n.get('fans',[])), 'zones:', [z['pct'] for z in n.get('zones',[])],
          '| power W:', n.get('power'), '| cards:', [(c['id'], c['c']) for c in n.get('cards',[])],
          '| hottest:', [(t['name'], t['c']) for t in n.get('temps',[])[:2]], '| nics:', len(n.get('nics',[])), '| err:', n.get('error') or n.get('errors'))
print('gaudi (watchdog):', [(g['id'], g['c'], g['w']) for g in j.get('gaudi',[])])
print('chart series:', sorted(j.get('series',{})))"
