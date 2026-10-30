#!/usr/bin/env bash
# Install dashboard v2 and reconfigure the router so it can switch between your plugin and stock llm-d.
set -uo pipefail
NS=hetero-pd-lab; HERE=$(cd "$(dirname "$0")" && pwd); REPO=$(cd "$HERE/../.." && pwd)
oc whoami >/dev/null 2>&1 || { echo "Cannot reach the cluster. Reconnect, run oc login, then re-run."; exit 1; }
echo "==== 1. Router: load both configs (your plugin + stock) into one release"
CH=$REPO/.cache/llm-d; BASE=$(tr -d '[:space:]' < "$REPO/plugin/llm-d-patch/BASE_COMMIT")
[ -d "$CH/.git" ] || git clone -q https://github.com/llm-d/llm-d-inference-scheduler.git "$CH"
git -C "$CH" checkout -q "$BASE"; CHART=$CH/config/charts/llm-d-router-standalone
helm dependency build "$CHART" >/dev/null 2>&1 || helm dependency update "$CHART" >/dev/null
SITE=""; [ -f "$REPO/lab/router/site.values.yaml" ] && SITE="-f $REPO/lab/router/site.values.yaml"
# The dashboard's mode switch edits the router's --config-file argument, so take that field back on upgrade.
HARGS=(upgrade --install hetero-pd "$CHART" -n $NS -f "$REPO/lab/router/common.values.yaml" -f "$HERE/modes.values.yaml" $SITE --wait --timeout 5m)
if helm upgrade --help 2>/dev/null | grep -q -- '--force-conflicts'; then HARGS+=(--force-conflicts); fi
helm "${HARGS[@]}" || exit 1
# Same image tag on every build: restart so the router pulls the image that was just built.
oc rollout restart deploy/hetero-pd-epp -n $NS >/dev/null && oc rollout status deploy/hetero-pd-epp -n $NS --timeout=5m || exit 1
oc get deploy hetero-pd-epp -n $NS -o jsonpath='router config file: {.spec.template.spec.containers[?(@.name=="epp")].args}{"\n"}' | tr ' ' '\n' | grep -A1 -- --config-file | tail -1
echo "==== 2. Dashboard"
oc create configmap hetero-pd-dashboard-web -n $NS --from-file=index.html=$HERE/web/index.html --from-file=server.py=$HERE/server.py --dry-run=client -o yaml | oc apply -f -
oc apply -n $NS -f $HERE/dashboard.yaml
oc apply -f - <<YAML
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata: {name: hetero-pd-dashboard-metrics-reader}
rules:
  - {nonResourceURLs: ["/metrics"], verbs: ["get"]}
  - {apiGroups: [""], resources: ["nodes"], verbs: ["get", "list"]}
  - {apiGroups: ["config.openshift.io"], resources: ["clusterversions"], verbs: ["get"]}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata: {name: hetero-pd-dashboard-metrics-reader}
roleRef: {apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: hetero-pd-dashboard-metrics-reader}
subjects: [{kind: ServiceAccount, name: hetero-pd-dashboard, namespace: $NS}]
YAML
oc rollout restart deploy/hetero-pd-dashboard -n $NS >/dev/null
oc rollout status deploy/hetero-pd-dashboard -n $NS --timeout=5m || exit 1
sleep 8
echo "==== 3. Check"
oc exec -n $NS deploy/hetero-pd-dashboard -- python3 -c "
import json,urllib.request
j=json.load(urllib.request.urlopen('http://localhost:8080/api/state'))
print('router mode:', j['mode']); print('cards found:', [p['name'] for p in j['live']['pods']]); print('router metrics readable:', j['live']['dec']['ok'])"
echo; echo "Dashboard: https://$(oc get route hetero-pd-dashboard -n $NS -o jsonpath='{.spec.host}')"
