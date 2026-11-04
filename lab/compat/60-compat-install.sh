#!/usr/bin/env bash
# Install the kv-compat labeler: every model-server pod gets llm-d.ai/kv-compat-key, computed
# from the settings that decide whether two pods can exchange KV. Pairs with different keys are
# tested automatically and wait for approval (dashboard > The stack > Card compatibility,
# or 62-approve-pair.sh). Then show the keys.
#   bash lab/compat/60-compat-install.sh [namespace] 2>&1 | tee 60-compat-install.txt
set -uo pipefail
NS=${1:-${NS:-hetero-pd-lab}}; HERE=$(cd "$(dirname "$0")" && pwd)
oc whoami >/dev/null 2>&1 || { echo "Not logged in. Run oc login first."; exit 1; }
oc create configmap kv-compat-scripts -n $NS --from-file=compat_labeler.py=$HERE/compat_labeler.py \
  --from-file=validate_pair.py=$HERE/validate_pair.py --dry-run=client -o yaml | oc apply -f - >/dev/null
oc apply -n $NS -f $HERE/compat.yaml
oc rollout restart deploy/kv-compat-labeler -n $NS >/dev/null 2>&1
oc rollout status deploy/kv-compat-labeler -n $NS --timeout=3m || exit 1
echo "waiting 60 s for the first pass..."; sleep 60
echo; echo "==== Keys (same key = can exchange KV; different = blocked until validated)"
oc get pods -n $NS -l llm-d.ai/role -o custom-columns='POD:.metadata.name,ROLE:.metadata.labels.llm-d\.ai/role,CLASS:.metadata.labels.llm-d\.ai/accelerator-class,KEY:.metadata.labels.llm-d\.ai/kv-compat-key'
echo; echo "==== Why (inputs behind each key)"
for p in $(oc get pods -n $NS -l llm-d.ai/role -o name); do
  echo "-- ${p#pod/}"
  oc get $p -n $NS -o jsonpath='{.metadata.annotations.llm-d\.ai/kv-compat-inputs}' | python3 -m json.tool 2>/dev/null | sed 's/^/   /' || echo "   (no key yet)"
done
# The dashboard's Card compatibility panel (Stack tab) reads and approves pairs: give it access.
if oc get deploy hetero-pd-dashboard -n $NS >/dev/null 2>&1; then
  D=$HERE/../dashboard2
  sed "s#hetero-pd-lab#$NS#g" $D/dashboard.yaml | oc apply -n $NS -f - >/dev/null
  oc create configmap hetero-pd-dashboard-web -n $NS --from-file=index.html=$D/web/index.html --from-file=server.py=$D/server.py --dry-run=client -o yaml | oc apply -f - >/dev/null
  oc rollout restart deploy/hetero-pd-dashboard -n $NS >/dev/null && echo "dashboard updated: The stack > Card compatibility"
fi
echo; echo "==== Pairs with different keys (tested automatically, then waiting for your approval)"
NS=$NS bash $HERE/62-approve-pair.sh list 2>&1 || true
echo; echo "==== Labeler log"; oc logs deploy/kv-compat-labeler -n $NS --tail=20
