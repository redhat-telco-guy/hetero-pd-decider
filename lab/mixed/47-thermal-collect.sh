#!/usr/bin/env bash
# Collect the in-cluster thermal test: phases from the job, every temperature reading from the watchdog,
# new Gaudi kernel messages since the start; build the summary. Safe to run while it is still going.
#   bash lab/mixed/47-thermal-collect.sh
set -uo pipefail
REPO=$(cd "$(dirname "$0")/../.." && pwd); NS=hetero-pd-lab
oc whoami >/dev/null 2>&1 || { echo "Not logged in. Run oc login first."; exit 1; }
OUT=$REPO/thermal-test-$(date +%Y%m%d-%H%M); mkdir -p $OUT
oc get job gaudi-thermal-test -n $NS -o jsonpath='job: active={.status.active} succeeded={.status.succeeded} failed={.status.failed}{"\n"}'
oc logs -n $NS job/gaudi-thermal-test > $OUT/job.log 2>&1
oc logs -n $NS deploy/gaudi-watchdog --since=3h > $OUT/incluster-watchdog.log 2>&1
{ echo "time,phase"; grep '^phase,' $OUT/job.log | cut -d, -f2-; } > $OUT/phases.csv
{ echo "time,serial,chip_c,board_c,power_w,util_pct"; grep '^csv,[0-9]' $OUT/incluster-watchdog.log | cut -d, -f2-; } > $OUT/all-readings.csv
GNODE=$(oc get nodes -l feature.node.kubernetes.io/pci-1da3.present=true -o jsonpath='{.items[0].metadata.name}')
oc debug node/$GNODE -q -- chroot /host sh -c 'dmesg -T | grep -i habanalabs' > $OUT/dmesg-after.txt 2>&1
[ -f $REPO/.thermal-dmesg-before.txt ] && cp $REPO/.thermal-dmesg-before.txt $OUT/dmesg-before.txt
echo "==== Test log"; grep -v '^phase,' $OUT/job.log | tail -12
echo "==== New Gaudi kernel messages since the start"
diff <(sort -u $OUT/dmesg-before.txt 2>/dev/null) <(sort -u $OUT/dmesg-after.txt) | grep '^>' | sed 's/^> /  /' | tee $OUT/dmesg-new.txt | tail -15
[ -s $OUT/dmesg-new.txt ] || echo "  none"
echo "==== Summary per phase and card (times UTC)"
python3 - $OUT <<'PY' | tee $OUT/summary.txt
import csv, sys, os
out = sys.argv[1]
ph = list(csv.DictReader(open(os.path.join(out, 'phases.csv'))))
if not ph: print("no phases yet: the job has not started or its log is gone"); sys.exit()
last = ph[-1]['time'] if ph[-1]['phase'] == 'end' else '99:99:99'
rows = [r for r in csv.DictReader(open(os.path.join(out, 'all-readings.csv'))) if ph[0]['time'] <= r['time'] <= last]
def phase(t):
    p = None
    for x in ph:
        if x['time'] <= t: p = x['phase']
    return p
agg = {}
for r in rows:
    a = agg.setdefault((phase(r['time']), r['serial']), {'n': 0, 'max': 0, 'pw': 0, 'last': 0})
    c = max(float(r['chip_c']), float(r['board_c'])); a['n'] += 1; a['max'] = max(a['max'], c); a['pw'] = max(a['pw'], float(r['power_w'])); a['last'] = c
print(f"{'phase':<16}{'starts':<10}{'card':<13}{'readings':>9}{'max C':>8}{'end C':>8}{'max W':>8}")
for x in ph:
    for (p, s), a in sorted(agg.items()):
        if p == x['phase'] and p != 'end': print(f"{p:<16}{x['time']:<10}{s:<13}{a['n']:>9}{a['max']:>8.0f}{a['last']:>8.0f}{a['pw']:>8.0f}")
PY
grep -h 'WATCHDOG.*stopping' -A3 $OUT/incluster-watchdog.log | tail -4
echo; echo "Saved in: $OUT"
