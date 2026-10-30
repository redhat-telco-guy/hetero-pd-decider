#!/usr/bin/env bash
# Read-only: where the heat test is, card temperatures, fans, and the Gaudi model server's start-up.
#   bash lab/hwmon/54-heat-status.sh
NS=hetero-pd-lab
oc exec -n $NS deploy/hetero-pd-dashboard -- python3 -c "
import json,time,urllib.request
j=json.load(urllib.request.urlopen('http://localhost:8080/api/hw')); h=j.get('heat',{}); now=time.time()
print('HEAT TEST:', h.get('phase'), '| running:', h.get('running'), '| target:', h.get('target'), '| cards:', h.get('cards'), '| per card:', h.get('users'), '| minutes:', h.get('minutes'))
print('  ', h.get('msg'))
if h.get('started'): print('   load for', int(min(now,h['until'])-h['started']), 's | requests', h.get('done'), '| errors', h.get('errors'), h.get('lastErr') or '')
print('GAUDI:', [(g['id'], str(int(g['c']))+' C', str(int(g['w']))+' W', str(int(g['util']))+'%') for g in j.get('gaudi',[])])
for n in j.get('nodes',[]):
    print(n.get('node','?').split('.')[0].upper()+':', 'fan setting', [z['pct'] for z in n.get('zones',[])] or '-', '| fan rpm', int(sum(f['rpm'] for f in n.get('fans',[]))/max(1,len(n.get('fans',[])))),
          '| power', n.get('power'), 'W | cards', [(c['id'], c['c'], c['w']) for c in n.get('cards',[])])
print('WATCHDOG:', j.get('watchdog',[])[-2:])"
echo; echo "GAUDI MODEL SERVER:"; oc get pods -n $NS -l llm-d.ai/accelerator-class=intel-gaudi3 -o wide 2>/dev/null | cut -c1-110
P=$(oc get pods -n $NS -l llm-d.ai/accelerator-class=intel-gaudi3 -o name 2>/dev/null | head -1)
[ -n "$P" ] && { echo "  last log lines:"; oc logs -n $NS $P -c modelserver --tail=6 2>&1 | cut -c1-160 | sed 's/^/    /'; }
