#!/usr/bin/env bash
# Back up everything before the cluster is rebuilt (read-only on the cluster):
#   1. all cluster results and configs (34-export-lab.sh)
#   2. the new hardware work: live panel snapshot with the last hour of readings, heat test state, watchdog log,
#      hw-monitor and Gaudi logs, live deployment specs, dashboard permissions
#   3. every evidence file on this laptop (thermal tests, BMC readings, health checks)
#   4. one .tgz of the whole repo (code, scripts, dashboard, hw-monitor, archives), checked after writing
#   bash lab/scripts/55-backup-before-rebuild.sh 2>&1 | tee 55-backup.txt
set -uo pipefail
NS=hetero-pd-lab; REPO=$(cd "$(dirname "$0")/../.." && pwd); DAY=$(date +%Y-%m-%d)
D=$REPO/lab-archive/$DAY; H=$D/hardware; E=$D/evidence; mkdir -p $H $E
hr() { printf '\n==== %s ====\n' "$1"; }
oc whoami >/dev/null 2>&1 || { echo "Cannot reach the cluster. Reconnect, run oc login, then re-run."; exit 1; }
save() { local f=$1; shift; "$@" > "$f" 2>&1 || echo "  (failed: $*)"; echo "  $(basename $f): $(wc -c < "$f" | tr -d ' ') bytes"; }

hr "1. Cluster results and configs (34-export-lab.sh)"
bash $REPO/lab/scripts/34-export-lab.sh 2>&1 | grep -E "====|runs:|bytes|failed" | grep -v "^$" | tail -40

hr "2. Hardware panel, heat test, watchdog"
save $H/api-hw-snapshot.json oc exec -n $NS deploy/hetero-pd-dashboard -- python3 -c "import urllib.request;print(urllib.request.urlopen('http://localhost:8080/api/hw').read().decode())"
save $H/gaudi-watchdog.log oc logs -n $NS deploy/gaudi-watchdog
for p in $(oc get pods -n $NS -l app=hw-monitor -o name); do save $H/$(basename $p).log oc logs -n $NS $p; done
P=$(oc get pods -n $NS -l llm-d.ai/accelerator-class=intel-gaudi3 -o name | head -1)
[ -n "$P" ] && save $H/gaudi-modelserver.log oc logs -n $NS $P -c modelserver
save $H/deployments-live.yaml oc get deploy -n $NS -o yaml
save $H/daemonsets-live.yaml oc get ds -n $NS -o yaml
save $H/dashboard-rbac.yaml oc get role,rolebinding -n $NS -o yaml
save $H/events.txt oc get events -n $NS --sort-by=.lastTimestamp
save $H/nodes.yaml oc get nodes -o yaml
python3 - "$H/api-hw-snapshot.json" <<'PY'
import json, sys
j = json.load(open(sys.argv[1])); h = j.get("heat", {})
print("  heat test:", h.get("phase"), "|", h.get("target"), "|", h.get("msg"))
print("  chart series saved:", {k: len(v) for k, v in j.get("series", {}).items()})
PY

hr "3. Evidence files from this laptop"
cd $REPO
cp -p [0-9][0-9]-*.txt worker2-cooling-evidence.txt gaudi-temps.csv gaudi-worker2-evidence.txt hw.txt thermal-test.txt $E/ 2>/dev/null
for t in thermal-test-*; do [ -d "$t" ] && cp -Rp "$t" $E/; done
echo "  $(ls $E | wc -l | tr -d ' ') files and folders in $(basename $D)/evidence"

hr "4. Full backup of the repo"
OUT=$REPO/lab-archive/hetero-pd-decider-full-backup-$DAY.tgz
tar -czf "$OUT" -C "$(dirname "$REPO")" --exclude="$(basename "$REPO")/.cache" --exclude="$(basename "$REPO")/lab-archive/*.tgz" --exclude="*/_to_delete" "$(basename "$REPO")"
N=$(tar -tzf "$OUT" | wc -l | tr -d ' ')
echo "  $(basename $OUT): $(du -h "$OUT" | cut -f1), $N entries, sha256 $(shasum -a 256 "$OUT" | cut -c1-16)…"
for f in lab/hwmon/collector.py lab/hwmon/hw-monitor.yaml lab/hwmon/53-hw-monitor.sh lab/dashboard2/server.py lab/dashboard2/web/index.html \
         lab/mixed/watchdog.py lab/mixed/45-watchdog-incluster.sh plugin/src/hetero/decide.go lab-archive/$DAY/hardware/api-hw-snapshot.json; do
  tar -tzf "$OUT" | grep -q "/$f$" && echo "  ok      $f" || echo "  MISSING $f"
done
echo; echo "Done. Keep lab-archive/ (or copy it off this laptop) before the cluster is rebuilt."
