#!/usr/bin/env bash
# Rebuild the router with the current plugin code and redeploy router + dashboard.
# Run with no traffic and no test suite running.
set -uo pipefail
NS=hetero-pd-lab; REPO=$(cd "$(dirname "$0")/../.." && pwd)
hr() { printf '\n==== %s ====\n' "$1"; }
oc whoami >/dev/null 2>&1 || { echo "Cannot reach the cluster. Reconnect, run oc login, then re-run."; exit 1; }
hr "1. Rebuild the router image (runs the plugin tests)"
bash $REPO/lab/scripts/08-epp-build.sh 2>&1 | grep -E -- '--- (PASS|FAIL)|^ok|FAIL|EPP BUILD|error' | grep -v '^Copying'
oc get builds -n $NS --sort-by=.metadata.creationTimestamp | tail -1 | grep -q Complete || { echo "Router build failed; stopping. See: oc logs -n $NS bc/epp-hetero"; exit 1; }
hr "2. Redeploy router and dashboard"
bash $REPO/lab/dashboard2/deploy.sh 2>&1 | tail -8
