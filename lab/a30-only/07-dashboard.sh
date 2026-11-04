#!/usr/bin/env bash
# The lab dashboard: how the plugin decides, router mode switch, traffic and test suites, results.
source "$(dirname "$0")/lib.sh"; login
D=$REPO/lab/dashboard2
oc create configmap hetero-pd-dashboard-web -n $NS --from-file=index.html=$D/web/index.html --from-file=server.py=$D/server.py --dry-run=client -o yaml | oc apply -f -
# The dashboard manifest avoids the first lab's broken Gaudi node by hostname; drop that rule here.
sed "s#hetero-pd-lab#$NS#g; s#worker2.ai154.dl154.dfw.ocp.run#no-such-node#; s#Qwen/Qwen2.5-7B-Instruct#$MODEL#" $D/dashboard.yaml | oc apply -n $NS -f -
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
oc rollout restart deploy/hetero-pd-dashboard -n $NS >/dev/null; oc rollout status deploy/hetero-pd-dashboard -n $NS --timeout=5m || die "Dashboard did not start."
sleep 8
oc exec -n $NS deploy/hetero-pd-dashboard -- python3 -c "
import json,urllib.request
j=json.load(urllib.request.urlopen('http://localhost:8080/api/state'))
print('  router mode:', j['mode'].get('current'), '| ready:', j['mode'].get('ready')); print('  cards found:', [p['name'] for p in j['live']['pods']]); print('  router metrics readable:', j['live']['dec']['ok'])"
echo "  Dashboard: https://$(oc get route hetero-pd-dashboard -n $NS -o jsonpath='{.spec.host}')"
