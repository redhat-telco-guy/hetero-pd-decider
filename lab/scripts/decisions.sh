#!/usr/bin/env bash
# Show hetero-pd-decider decisions: counters by reason, and the latest
# per-request estimates from the EPP log (needs router flags v: 4).
#
#   ./decisions.sh [release] [namespace]
set -euo pipefail

RELEASE=${1:-hetero-pd}
NS=${2:-hetero-pd-lab}
SVC="${RELEASE}-epp"

kubectl -n "$NS" port-forward "svc/$SVC" 19090:9090 >/dev/null 2>&1 &
PF=$!
trap 'kill $PF 2>/dev/null' EXIT
sleep 2

METRICS=$(curl -sf localhost:19090/metrics || \
  curl -sf -H "Authorization: Bearer $(kubectl create token default -n "$NS" 2>/dev/null || oc whoami -t)" localhost:19090/metrics || true)
if [ -z "$METRICS" ]; then
  echo "could not read EPP metrics on $SVC:9090 (check the service name with: kubectl -n $NS get svc)" >&2
else
  echo "== hetero-pd-decider decisions by reason =="
  echo "$METRICS" | grep '^llm_d_epp_hetero_pd_decision_total' | \
    sed -E 's/.*reason="([^"]+)",remote_prefill="([^"]+)"\} (.*)/\1 remote=\2 \3/' | sort | column -t
  echo
  echo "== routing paths (all deciders) =="
  echo "$METRICS" | grep '^llm_d_epp_disagg_decision_total' | \
    sed -E 's/.*decision_type="([^"]+)".*\} (.*)/\1 \2/' | sort | column -t
fi

echo
echo "== last 10 per-request estimates =="
kubectl -n "$NS" logs "deploy/$SVC" -c epp --tail=5000 2>/dev/null | \
  grep '"hetero-pd-decider decision"' | tail -10 || \
  echo "(none: is the router running with flags v: 4 and container name epp?)"
