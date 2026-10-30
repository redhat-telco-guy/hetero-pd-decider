#!/usr/bin/env bash
# Apply the Gaudi memory settings and watch until ready.
NS=hetero-pd-lab; REPO=$(cd "$(dirname "$0")/../.." && pwd)
oc whoami >/dev/null 2>&1 || { echo "Cannot reach cluster; reconnect and oc login, then re-run."; exit 1; }
oc apply -n $NS -k $REPO/lab/modelserver/layout-a-a30-prefill
# Recreate strategy takes effect on the next rollout; clear any pod still holding the card.
oc delete pod -n $NS -l app=decode-gaudi3 --wait=false
oc rollout status deploy/decode-gaudi3 -n $NS --timeout=5s >/dev/null 2>&1
sleep 20
exec bash $REPO/lab/scripts/14-gaudi-watch.sh
