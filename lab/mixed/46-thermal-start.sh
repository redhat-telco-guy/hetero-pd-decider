#!/usr/bin/env bash
# Start the Gaudi thermal test as a Job inside the cluster (about 30 min). It does not need this laptop
# once started: a lost connection changes nothing. Collect the results any time later with 47-thermal-collect.sh.
#   bash lab/mixed/46-thermal-start.sh
set -uo pipefail
A=$(cd "$(dirname "$0")" && pwd); REPO=$(cd "$A/../.." && pwd); NS=hetero-pd-lab
oc whoami >/dev/null 2>&1 || { echo "Not logged in. Run oc login first."; exit 1; }
pkill -f 42-gaudi-watchdog.sh 2>/dev/null; rm -f $REPO/.watchdog.pid
echo "1. Watchdog in the cluster (the only temperature reader; stops the Gaudis at 80 C or after 30 s blind)"
bash $A/45-watchdog-incluster.sh 80 >/dev/null 2>&1
oc get deploy gaudi-watchdog -n $NS -o jsonpath='{.status.readyReplicas}' | grep -q 1 || { echo "Watchdog not running; not starting the test."; exit 1; }
oc logs -n $NS deploy/gaudi-watchdog --tail=3
echo "2. Record the start time and the Gaudi kernel log"
date -u +%Y-%m-%dT%H:%M:%SZ > $REPO/.thermal-start
GNODE=$(oc get nodes -l feature.node.kubernetes.io/pci-1da3.present=true -o jsonpath='{.items[0].metadata.name}')
oc debug node/$GNODE -q -- chroot /host sh -c 'dmesg -T | grep -i habanalabs' > $REPO/.thermal-dmesg-before.txt 2>&1
echo "3. Start the test job (stops any earlier one)"
oc create configmap thermal-test -n $NS --from-file=thermal_test.py=$A/thermal_test.py --dry-run=client -o yaml | oc apply -f - >/dev/null
oc delete job gaudi-thermal-test -n $NS --ignore-not-found >/dev/null
oc apply -f - <<YAML
apiVersion: batch/v1
kind: Job
metadata: {name: gaudi-thermal-test, namespace: $NS}
spec:
  backoffLimit: 0
  template:
    spec:
      serviceAccountName: gaudi-watchdog
      restartPolicy: Never
      containers:
        - name: test
          image: registry.access.redhat.com/ubi9/python-311:latest
          command: ["python3", "-u", "/app/thermal_test.py"]
          env: [{name: STEPS, value: "${STEPS:-2 4 8 16}"}, {name: STEP_MIN, value: "${STEP_MIN:-3}"}]
          volumeMounts: [{name: app, mountPath: /app}]
      volumes: [{name: app, configMap: {name: thermal-test}}]
YAML
echo; echo "Started at $(date +%H:%M). It runs on its own for about 30 minutes."
echo "Watch it (optional):   oc logs -n $NS job/gaudi-thermal-test -f"
echo "Results, any time:     bash lab/mixed/47-thermal-collect.sh"
