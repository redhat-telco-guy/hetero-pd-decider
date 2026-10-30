#!/usr/bin/env bash
# Switch to layout D (A30 -> A30) while the Gaudi node is down, then run the correctness gate.
set -uo pipefail
NS=hetero-pd-lab; REPO=$(cd "$(dirname "$0")/../.." && pwd)
hr() { printf '\n==== %s ====\n' "$1"; }
oc whoami >/dev/null 2>&1 || { echo "Cannot reach cluster; reconnect and oc login, then re-run."; exit 1; }

hr "Park the Gaudi decode deployment (keeps its config; scale back to 1 when worker2 is fixed)"
oc scale deploy/decode-gaudi3 -n $NS --replicas=0

hr "Deploy layout D: decode on worker1's second A30"
oc apply -n $NS -k $REPO/lab/modelserver/layout-d-a30-pair
for i in $(seq 1 60); do
  r=$(oc get deploy decode-a30 -n $NS -o jsonpath='{.status.readyReplicas}')
  L=$(oc logs -n $NS deploy/decode-a30 -c modelserver --tail=1 2>/dev/null | tr '\r' '\n' | tail -1 | cut -c1-110)
  echo "[$i $(date +%H:%M)] decode-a30 ready=${r:-0} | $L"; [ "${r:-0}" -ge 1 ] && break
  oc get pods -n $NS -l app=decode-a30 --no-headers | grep -qE 'CrashLoop|Error|ImagePull' && { oc logs -n $NS deploy/decode-a30 -c modelserver --tail=30; exit 1; }
  sleep 15
done
oc get pods -n $NS -o wide | grep -v build
nvidia_alloc=$(oc get pods -n $NS -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.nodeName}{"\n"}{end}' | grep -E 'prefill-a30|decode-a30')
echo "$nvidia_alloc"

hr "Restart the router so it starts from a clean endpoint list"
oc rollout restart deploy/hetero-pd-epp -n $NS && oc rollout status deploy/hetero-pd-epp -n $NS --timeout=3m

hr "Correctness gate on A30 -> A30"
DECODE=decode-a30 bash $REPO/lab/scripts/12-correctness.sh
