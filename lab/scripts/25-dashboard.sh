#!/usr/bin/env bash
# Deploy (or update) the Hetero-PD dashboard on OpenShift and print its URL.
# Re-run after changing lab/dashboard/web/* or server.py; it restarts the pod to pick them up.
set -uo pipefail
NS=hetero-pd-lab; REPO=$(cd "$(dirname "$0")/../.." && pwd); D=$REPO/lab/dashboard
oc whoami >/dev/null 2>&1 || { echo "Cannot reach cluster; reconnect and oc login."; exit 1; }
oc create configmap hetero-pd-dashboard-web -n $NS \
  --from-file=index.html=$D/web/index.html --from-file=results.json=$D/web/results.json --from-file=server.py=$D/server.py \
  --dry-run=client -o yaml | oc apply -f -
oc apply -n $NS -f $D/dashboard.yaml
# The router's /metrics needs a token allowed to read it (cluster-scoped, read-only).
oc apply -f - <<YAML
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata: {name: hetero-pd-dashboard-metrics-reader}
rules: [{nonResourceURLs: ["/metrics"], verbs: ["get"]}]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata: {name: hetero-pd-dashboard-metrics-reader}
roleRef: {apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: hetero-pd-dashboard-metrics-reader}
subjects: [{kind: ServiceAccount, name: hetero-pd-dashboard, namespace: $NS}]
YAML
oc rollout restart deploy/hetero-pd-dashboard -n $NS >/dev/null
oc rollout status deploy/hetero-pd-dashboard -n $NS --timeout=5m
sleep 8
echo "---- live feed check"
oc exec -n $NS deploy/hetero-pd-dashboard -- python3 -c "
import json,urllib.request
j=json.load(urllib.request.urlopen('http://localhost:8080/live.json'))
print('pods found:', sorted(j['pods']))
print('scrape issues:', j['errors'] or 'none')
s=j['history'][-1] if j['history'] else {}
print('router decision series:', len((s.get('epp') or {}).get('hetero',{})), '| all-decider series:', len((s.get('epp') or {}).get('disagg',{})))"
echo
echo "Dashboard: https://$(oc get route hetero-pd-dashboard -n $NS -o jsonpath='{.spec.host}')"
