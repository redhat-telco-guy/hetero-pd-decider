#!/usr/bin/env bash
# Install (or update) the Gaudi watchdog as a pod inside the cluster, so it keeps protecting the cards
# even if this laptop disconnects. Readings: oc logs -n hetero-pd-lab deploy/gaudi-watchdog
#   bash lab/mixed/45-watchdog-incluster.sh [limit_C]
set -uo pipefail
A=$(cd "$(dirname "$0")" && pwd); NS=hetero-pd-lab; HNS=habana-ai-operator; LIMIT=${1:-80}
oc whoami >/dev/null 2>&1 || { echo "Not logged in. Run oc login first."; exit 1; }
oc create configmap gaudi-watchdog -n $NS --from-file=watchdog.py=$A/watchdog.py --dry-run=client -o yaml | oc apply -f - >/dev/null
oc apply -f - <<YAML
apiVersion: v1
kind: ServiceAccount
metadata: {name: gaudi-watchdog, namespace: $NS}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata: {name: gaudi-watchdog, namespace: $NS}
rules:
  - {apiGroups: ["apps"], resources: ["deployments"], verbs: ["get", "list"]}
  - {apiGroups: ["apps"], resources: ["deployments/scale"], verbs: ["get", "patch", "update"]}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: {name: gaudi-watchdog, namespace: $NS}
roleRef: {apiGroup: rbac.authorization.k8s.io, kind: Role, name: gaudi-watchdog}
subjects: [{kind: ServiceAccount, name: gaudi-watchdog, namespace: $NS}]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata: {name: gaudi-watchdog-read, namespace: $HNS}
rules: [{apiGroups: [""], resources: ["pods"], verbs: ["get", "list"]}]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: {name: gaudi-watchdog-read, namespace: $HNS}
roleRef: {apiGroup: rbac.authorization.k8s.io, kind: Role, name: gaudi-watchdog-read}
subjects: [{kind: ServiceAccount, name: gaudi-watchdog, namespace: $NS}]
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: gaudi-watchdog, namespace: $NS, labels: {app: gaudi-watchdog}}
spec:
  replicas: 1
  selector: {matchLabels: {app: gaudi-watchdog}}
  template:
    metadata: {labels: {app: gaudi-watchdog}}
    spec:
      serviceAccountName: gaudi-watchdog
      containers:
        - name: watchdog
          image: registry.access.redhat.com/ubi9/python-311:latest
          command: ["python3", "-u", "/app/watchdog.py"]
          env:
            - {name: LIMIT, value: "$LIMIT"}
            - {name: EVERY, value: "5"}
            - {name: BLIND_S, value: "30"}
          resources: {requests: {cpu: 50m, memory: 64Mi}, limits: {memory: 256Mi}}
          volumeMounts: [{name: app, mountPath: /app}]
      volumes: [{name: app, configMap: {name: gaudi-watchdog}}]
YAML
oc rollout restart deploy/gaudi-watchdog -n $NS >/dev/null 2>&1
oc rollout status deploy/gaudi-watchdog -n $NS --timeout=3m || exit 1
sleep 8; oc logs -n $NS deploy/gaudi-watchdog --tail=5
