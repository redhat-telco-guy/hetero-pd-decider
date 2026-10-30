#!/usr/bin/env bash
# Rebuild the router (EPP) with hetero-pd-decider. Binary builds ignore --build-arg,
# so BASE_COMMIT is baked into the uploaded Dockerfile. Success = build phase "Complete".
set -uo pipefail
NS=hetero-pd-lab
REPO=$(cd "$(dirname "$0")/../.." && pwd); SRC=$REPO/lab/build/epp
hr() { printf '\n==== %s ====\n' "$1"; }
oc whoami >/dev/null 2>&1 || { echo "Cannot reach cluster; reconnect and oc login, then re-run."; exit 1; }

BASE=$(tr -d '[:space:]' < "$REPO/plugin/llm-d-patch/BASE_COMMIT")
UP=$(mktemp -d)
cp "$REPO/plugin/llm-d-patch/hetero-pd-decider.patch" "$UP/"
sed "s/^ARG BASE_COMMIT$/ARG BASE_COMMIT=$BASE/" "$SRC/Dockerfile" > "$UP/Dockerfile"
grep -q "ARG BASE_COMMIT=$BASE" "$UP/Dockerfile" || { echo "Failed to bake BASE_COMMIT into Dockerfile"; exit 1; }
echo "Building at llm-d commit $BASE"

hr "Router (EPP) build: clone, patch, vet, test, compile (~10-15 min)"
# Build on worker1 (worker2 is under repair) with room for the Go toolchain.
oc patch bc epp-hetero -n $NS --type=merge -p '{"spec":{"nodeSelector":{"kubernetes.io/hostname":"worker1.ai154.dl154.dfw.ocp.run"},"resources":{"limits":{"cpu":"8","memory":"16Gi"}}}}' >/dev/null
B=$(oc start-build epp-hetero -n $NS --from-dir="$UP" -o name)
echo "$B"
oc logs -f "$B" -n $NS 2>&1
for i in $(seq 1 20); do
  PH=$(oc get "$B" -n $NS -o jsonpath='{.status.phase}')
  case "$PH" in Complete|Failed|Error|Cancelled) break;; esac; sleep 5
done
rm -rf "$UP"

hr "Result"
oc get builds -n $NS
oc get istag -n $NS 2>&1
if [ "$PH" = "Complete" ]; then echo "EPP BUILD: SUCCESS (plugin compiled, vetted, tests passed)"
else echo "EPP BUILD: FAILED (phase=$PH). Reason: $(oc get "$B" -n $NS -o jsonpath='{.status.message}')"; fi

hr "Gaudi build progress (last 15 log lines)"
oc logs bc/vllm-gaudi-nixl -n $NS --tail=15 2>&1 | cut -c1-200
