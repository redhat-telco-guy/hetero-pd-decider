#!/usr/bin/env bash
# Leave this running in its own terminal tab: every 2 minutes it writes the suite status to
# suite-status.txt in the repo folder, so you (or anyone helping) can read the latest state from a file.
# It only reads from the cluster. Stop with Ctrl-C.
#   bash lab/aws-nvidia/75-watch-status.sh
cd "$(dirname "$0")/../.."
while true; do
  { date; bash lab/aws-nvidia/73-suite-status.sh; echo; echo "==== Restarts"; oc get pods -n ${NS:-hetero-pd-aws} -l llm-d.ai/role \
      -o custom-columns='POD:.metadata.name,RESTARTS:.status.containerStatuses[0].restartCount,LAST-EXIT:.status.containerStatuses[0].lastState.terminated.reason'; } > suite-status.tmp 2>&1
  mv suite-status.tmp suite-status.txt
  echo "$(date +%H:%M) status written"; sleep 120
done
