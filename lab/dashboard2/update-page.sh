#!/usr/bin/env bash
# Publish only the dashboard page and server (no router restart).
set -uo pipefail
NS=hetero-pd-lab; HERE=$(cd "$(dirname "$0")" && pwd)
oc create configmap hetero-pd-dashboard-web -n $NS --from-file=index.html=$HERE/web/index.html --from-file=server.py=$HERE/server.py --dry-run=client -o yaml | oc apply -f - || exit 1
oc rollout restart deploy/hetero-pd-dashboard -n $NS >/dev/null && oc rollout status deploy/hetero-pd-dashboard -n $NS --timeout=3m || exit 1
echo "Dashboard: https://$(oc get route hetero-pd-dashboard -n $NS -o jsonpath='{.spec.host}')"
