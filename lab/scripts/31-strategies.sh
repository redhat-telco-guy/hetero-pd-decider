#!/usr/bin/env bash
# Switch the lab to the plugin's auto strategy (stock answer first, overruled only when clearly cheaper):
#   1. keep only the calibrated runs in the dashboard history (the first, uncalibrated suite is in suite-results.json)
#   2. rebuild the router image with the new decide.go
#   3. redeploy the router (your plugin in auto is the default) and the dashboard
# Run with no traffic and no test suite running.
set -uo pipefail
NS=hetero-pd-lab; REPO=$(cd "$(dirname "$0")/../.." && pwd); S=$REPO/lab/scripts
PY=$(command -v python || command -v python3)
hr() { printf '\n==== %s ====\n' "$1"; }
oc whoami >/dev/null 2>&1 || { echo "Cannot reach the cluster. Reconnect, run oc login, then re-run."; exit 1; }

hr "1. Dashboard history: keep the calibrated runs only"
oc get configmap hetero-pd-dashboard-results -n $NS -o jsonpath='{.data.history\.json}' > "$REPO/suite-results-backup-$(date +%Y%m%d-%H%M).json"
$PY - "$REPO" <<'PYEOF'
import json, subprocess, sys, os
repo = sys.argv[1]
cur = json.loads(subprocess.check_output(["oc", "get", "configmap", "hetero-pd-dashboard-results", "-n", "hetero-pd-lab",
                                          "-o", "jsonpath={.data.history\\.json}"]) or b"[]")
first = os.path.join(repo, "suite-results.json")
old = {round(r.get("startedAt", 0)) for r in json.load(open(first))} if os.path.exists(first) else set()
keep = [r for r in cur if round(r.get("startedAt", 0)) not in old]
patch = json.dumps({"data": {"history.json": json.dumps(keep)}})
subprocess.check_call(["oc", "patch", "configmap", "hetero-pd-dashboard-results", "-n", "hetero-pd-lab", "--type", "merge", "-p", patch])
print(f"kept {len(keep)} calibrated runs, removed {len(cur) - len(keep)} from the first suite")
PYEOF

hr "2. Rebuild the router image with the auto strategy"
bash $S/08-epp-build.sh 2>&1 | grep -E -- '--- (PASS|FAIL)|^ok|FAIL|EPP BUILD|error' | grep -v '^Copying'
oc get builds -n $NS --sort-by=.metadata.creationTimestamp | tail -1 | grep -q Complete || { echo "Router build failed; stopping. See the build log: oc logs -n $NS bc/epp-hetero"; exit 1; }

hr "3. Redeploy the router (default: your plugin, auto) and the dashboard"
bash $REPO/lab/dashboard2/deploy.sh 2>&1 | tail -8
echo; echo "Done. On the dashboard: Traffic tab > Test suite > Run test suite (stock vs your plugin, auto)."
