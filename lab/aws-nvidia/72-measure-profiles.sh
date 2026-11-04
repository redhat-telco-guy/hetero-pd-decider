#!/usr/bin/env bash
# Measure each GPU type's prefill speed and write the router config for this lab
# (lab/aws-nvidia/modes.values.aws.yaml): the plugin's profiles, KV size and approved pairs.
#   CONFIG=lab/aws-nvidia/config.env bash lab/aws-nvidia/72-measure-profiles.sh
export CONFIG=${CONFIG:-$(cd "$(dirname "$0")" && pwd)/config.env}
source "$(dirname "$0")/../a30-only/lib.sh"; login
H=$REPO/lab/aws-nvidia; OUT=$H/modes.values.aws.yaml; JOB=prefill-speed-$(date +%H%M%S)
oc get sa kv-compat -n $NS >/dev/null 2>&1 || die "Run lab/compat/60-compat-install.sh $NS first."
oc create configmap aws-measure -n $NS --from-file=measure_prefill.py=$H/measure_prefill.py --dry-run=client -o yaml | oc apply -f - >/dev/null
oc apply -n $NS -f - <<YAML >/dev/null
apiVersion: batch/v1
kind: Job
metadata: {name: $JOB}
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 86400
  template:
    spec:
      serviceAccountName: kv-compat
      restartPolicy: Never
      containers:
        - name: measure
          image: registry.access.redhat.com/ubi9/python-311:latest
          command: ["python3", "-u", "/app/measure_prefill.py"]
          env: [{name: MODEL, value: "$MODEL"}]
          volumeMounts: [{name: app, mountPath: /app}]
      volumes: [{name: app, configMap: {name: aws-measure}}]
YAML
hr "Measuring prefill speed (about 2 minutes)"
oc wait --for=condition=complete job/$JOB -n $NS --timeout=15m >/dev/null 2>&1 || oc logs job/$JOB -n $NS
RES=$(oc logs job/$JOB -n $NS); echo "$RES"
PROFILES=$(echo "$RES" | grep -v '^#' | grep -E '^[a-z0-9-]+ [0-9]+$')
[ -n "$PROFILES" ] || die "No speeds measured."
hr "Writing $OUT"
python3 - "$REPO/lab/dashboard2/modes.values.yaml" "$OUT" "${KV_BYTES_PER_TOKEN:-28672}" "${APPROVED_PAIRS:-}" <<PY
import sys, re
src, out, kvb, approved = sys.argv[1:5]
prof = """$PROFILES""".split("\n")
lines, res, skip, ind = open(src).read().split("\n"), [], False, 0
for l in lines:
    s = l.strip()
    depth = len(l) - len(l.lstrip())
    if skip:
        if s and depth > ind:
            continue
        skip = False
    if s.startswith("profiles:"):
        ind = depth
        res.append(" " * ind + "profiles:                      # measured by 72-measure-profiles.sh")
        for p in prof:
            cls, rate = p.split()
            res += [" " * (ind + 2) + cls + ":", " " * (ind + 4) + "prefillTokensPerSec: " + rate]
        skip = True
        continue
    if s.startswith("kvBytesPerToken:"):
        l = re.sub(r"kvBytesPerToken: \d+.*", f"kvBytesPerToken: {kvb}         # {'$MODEL'}, fp16", l)
    if s.startswith("approvedPairs:") and approved:
        l = re.sub(r"approvedPairs: .*", "approvedPairs: [" + ", ".join(f'"{a.strip()}"' for a in approved.split(",") if a.strip()) + "]", l)
    res.append(l)
open(out, "w").write("\n".join(res))
PY
grep -n -A7 "profiles:" $OUT | head -12
echo; echo "Apply it:  CONFIG=$CONFIG MODES_VALUES=$OUT bash lab/a30-only/06-router.sh"
