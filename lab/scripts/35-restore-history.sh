#!/usr/bin/env bash
# Load saved test results into the dashboard on a (new) cluster, so old and new runs can be compared.
# Usage: bash lab/scripts/35-restore-history.sh lab-archive/2026-10-29/results/history.json [--merge]
#   --merge keeps the runs already on the cluster and adds the saved ones (duplicates skipped).
set -uo pipefail
NS=hetero-pd-lab; F=${1:?path to history.json}; MODE=${2:-replace}
oc whoami >/dev/null 2>&1 || { echo "Cannot reach the cluster. Run oc login first."; exit 1; }
python3 - "$F" "$MODE" <<'PY'
import json, subprocess, sys
f, mode = sys.argv[1], sys.argv[2]
saved = json.load(open(f))
for r in saved: r.setdefault("lab", "ai154 (A30 pair, Oct 2026)")   # tag where these runs came from
cur = []
if mode == "--merge":
    out = subprocess.run(["oc","get","configmap","hetero-pd-dashboard-results","-n","hetero-pd-lab","-o","jsonpath={.data.history\\.json}"],capture_output=True,text=True).stdout
    cur = json.loads(out or "[]")
seen = {(r.get("mode"), round(r.get("startedAt",0))) for r in cur}
allr = cur + [r for r in saved if (r.get("mode"), round(r.get("startedAt",0))) not in seen]
allr.sort(key=lambda r: -r.get("startedAt",0))
data = json.dumps({"apiVersion":"v1","kind":"ConfigMap","metadata":{"name":"hetero-pd-dashboard-results","namespace":"hetero-pd-lab"},"data":{"history.json":json.dumps(allr)}})
subprocess.run(["oc","apply","-f","-"],input=data,text=True,check=True)
print(f"history now holds {len(allr)} runs ({len(allr)-len(cur)} restored)")
PY
oc rollout restart deploy/hetero-pd-dashboard -n $NS >/dev/null 2>&1 && oc rollout status deploy/hetero-pd-dashboard -n $NS --timeout=3m
