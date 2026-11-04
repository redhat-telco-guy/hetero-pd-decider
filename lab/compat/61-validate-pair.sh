#!/usr/bin/env bash
# Validate a prefill -> decode handoff before allowing it (runs as a Job in the cluster).
#   bash lab/compat/61-validate-pair.sh <prefill deployment or pod> <decode deployment or pod> [prompts] 2>&1 | tee 61-validate.txt
# Example: bash lab/compat/61-validate-pair.sh prefill-a30 decode-gaudi3 30
# Prints PASS/FAIL and, on PASS between different keys, the approvedPairs entry for the router config.
set -uo pipefail
PREFILL=${1:?prefill deployment or pod}; DECODE=${2:?decode deployment or pod}; PROMPTS=${3:-30}
NS=${NS:-hetero-pd-lab}; MODEL=${MODEL:-Qwen/Qwen2.5-7B-Instruct}; HERE=$(cd "$(dirname "$0")" && pwd)
JOB=kv-validate-$(date +%H%M%S)
oc whoami >/dev/null 2>&1 || { echo "Not logged in. Run oc login first."; exit 1; }
oc get sa kv-compat -n $NS >/dev/null 2>&1 || oc apply -n $NS -f $HERE/compat.yaml >/dev/null
oc create configmap kv-compat-scripts -n $NS --from-file=compat_labeler.py=$HERE/compat_labeler.py \
  --from-file=validate_pair.py=$HERE/validate_pair.py --dry-run=client -o yaml | oc apply -f - >/dev/null
oc apply -n $NS -f - <<YAML >/dev/null
apiVersion: batch/v1
kind: Job
metadata: {name: $JOB, labels: {app: kv-validate}}
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 86400
  template:
    metadata: {labels: {app: kv-validate}}
    spec:
      serviceAccountName: kv-compat
      restartPolicy: Never
      containers:
        - name: validate
          image: registry.access.redhat.com/ubi9/python-311:latest
          command: ["python3", "-u", "/app/validate_pair.py"]
          env:
            - {name: PREFILL, value: "$PREFILL"}
            - {name: DECODE, value: "$DECODE"}
            - {name: MODEL, value: "$MODEL"}
            - {name: PROMPTS, value: "$PROMPTS"}
          volumeMounts: [{name: app, mountPath: /app}]
      volumes: [{name: app, configMap: {name: kv-compat-scripts}}]
YAML
echo "Job $JOB started (prefill $PREFILL -> decode $DECODE, $PROMPTS prompts). It keeps running if you disconnect;"
echo "read it later with: oc logs job/$JOB -n $NS"
oc wait --for=condition=Ready pod -l job-name=$JOB -n $NS --timeout=180s >/dev/null 2>&1
oc logs -f job/$JOB -n $NS
