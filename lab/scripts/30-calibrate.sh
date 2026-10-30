#!/usr/bin/env bash
# Calibrate the plugin on the lab:
#   1. rebuild the router with the new decide.go (handoffOverheadMs, stallFraction)
#   2. measure each card's reading speed and the handoff overhead (no other traffic!)
#   3. write the measured values into the router config and redeploy
# Run with no traffic and no test suite running.
set -uo pipefail
NS=hetero-pd-lab; MODEL=Qwen/Qwen2.5-7B-Instruct; DEC=${DECODE:-decode-a30}
REPO=$(cd "$(dirname "$0")/../.." && pwd); S=$REPO/lab/scripts; VALUES=$REPO/lab/dashboard2/modes.values.yaml
PY=$(command -v python || command -v python3)
hr() { printf '\n==== %s ====\n' "$1"; }
oc whoami >/dev/null 2>&1 || { echo "Cannot reach the cluster. Reconnect, run oc login, then re-run."; exit 1; }
$PY -c "import requests" 2>/dev/null || $PY -m pip install -q requests

hr "1. Rebuild the router image with the updated plugin"
bash $S/08-epp-build.sh 2>&1 | grep -E -- '--- (PASS|FAIL)|^ok|FAIL|EPP BUILD|error' | grep -v '^Copying'
oc get builds -n $NS --sort-by=.metadata.creationTimestamp | tail -1 | grep -q Complete || { echo "Router build failed; stopping. See the build log: oc logs -n $NS bc/epp-hetero"; exit 1; }

hr "2a. Reading speed of each card (direct to each engine, no router)"
pkill -f 'port-forward.*(18000|18200|18100)' 2>/dev/null; sleep 1
oc port-forward -n $NS deploy/prefill-a30 18000:8000 >/dev/null 2>&1 &
oc port-forward -n $NS deploy/$DEC 18200:8200 18100:8000 >/dev/null 2>&1 &
trap 'pkill -f "port-forward.*(18000|18200|18100)" 2>/dev/null' EXIT
sleep 6
PROF=$(cd $S && $PY profile_prefill.py --model $MODEL --target prefill=http://localhost:18000 --target decode=http://localhost:18200 --sizes 256,1024,2048,4096 --reps 3)
echo "$PROF"
RP=$(echo "$PROF" | awk '/^  prefill:/{f=1;next} f&&/prefillTokensPerSec/{print $2; exit}')
RD=$(echo "$PROF" | awk '/^  decode:/{f=1;next} f&&/prefillTokensPerSec/{print $2; exit}')
R=$(( (RP + RD) / 2 )); echo "A30 reading speed: prefill card $RP, decode card $RD -> using $R tokens/s"

hr "2b. Handoff overhead (same prompt size: local vs through the handoff)"
PIP=$(oc get pod -n $NS -l app=prefill-a30 -o jsonpath='{.items[0].status.podIP}')
HO=$(cd $S && $PY measure_handoff.py --engine http://localhost:18200 --sidecar http://localhost:18100 --prefill $PIP:8000 --model $MODEL --tokens 300 --reps 20)
echo "$HO"
H=$($PY -c "import json,sys;print(json.loads(sys.argv[1])['handoffOverheadMs'])" "$HO")
[ -n "$H" ] || { echo "Handoff measurement failed; using 300 ms"; H=300; }

hr "3. Write the measured values into the router config"
$PY - "$VALUES" "$R" "$H" <<'PYEOF'
import re, sys
p, rate, ho = sys.argv[1], int(sys.argv[2]), int(float(sys.argv[3]))
s = open(p).read()
a = s.index("hetero-pd-config.yaml: |"); b = s.index("stock-pd-config.yaml: |")
h = s[a:b]
h = re.sub(r"(nvidia-a30:\n\s+prefillTokensPerSec: )\d+", lambda m: m.group(1) + str(rate), h)
for key, val, note in (("handoffOverheadMs", ho, "measured: remote-path TTFT minus local TTFT"),
                       ("stallFraction", 0.1, "chunked prefill: running streams lose ~10% of a local prefill")):
    if key + ":" in h:
        h = re.sub(rf"{key}: [^\n]*", f"{key}: {val}   # {note}", h)
    else:
        h = h.replace("            avgQueuedPromptTokens:", f"            {key}: {val}   # {note}\n            avgQueuedPromptTokens:", 1)
s = s[:a] + h + s[b:]
open(p, "w").write(s)
print(h[h.index("- type: hetero-pd-decider"):h.index("schedulingProfiles")])
PYEOF

hr "4. Redeploy the router and dashboard with the calibrated config"
bash $REPO/lab/dashboard2/deploy.sh 2>&1 | tail -8
echo; echo "Calibration done. Now run the test suite again from the dashboard's Traffic tab."
