#!/usr/bin/env bash
# Build the llm-d router (EPP) with hetero-pd-decider inside the cluster: clone llm-d at the pinned
# commit, apply the plugin patch, go vet, run the plugin tests, compile. About 10-15 minutes.
source "$(dirname "$0")/lib.sh"; login
BASE=$(tr -d '[:space:]' < $REPO/plugin/llm-d-patch/BASE_COMMIT); NODE=$(first_a30)
[ -n "$NODE" ] || die "No A30 node found; run 02-gpus.sh first."
oc get bc epp-hetero -n $NS >/dev/null 2>&1 || \
  oc new-build -n $NS --name=epp-hetero --strategy=docker --binary --to=llm-d-router-endpoint-picker:hetero-pd-dev >/dev/null
# Workarounds: binary builds ignore --build-arg, so BASE_COMMIT is written into the uploaded Dockerfile;
# the Go build hit "newosproc" thread limits, so the Dockerfile caps GOMAXPROCS and the build gets 8 CPU / 16 GiB.
UP=$(mktemp -d); cp $REPO/plugin/llm-d-patch/hetero-pd-decider.patch $UP/
sed "s/^ARG BASE_COMMIT$/ARG BASE_COMMIT=$BASE/" $REPO/lab/build/epp/Dockerfile > $UP/Dockerfile
grep -q "ARG BASE_COMMIT=$BASE" $UP/Dockerfile || die "Could not pin BASE_COMMIT in the Dockerfile."
oc patch bc epp-hetero -n $NS --type=merge -p "{\"spec\":{\"nodeSelector\":{\"kubernetes.io/hostname\":\"$NODE\"},\"resources\":{\"limits\":{\"cpu\":\"8\",\"memory\":\"16Gi\"}}}}" >/dev/null
hr "Building at llm-d commit $BASE on $NODE"
B=$(oc start-build epp-hetero -n $NS --from-dir=$UP -o name); rm -rf $UP
oc logs -f $B -n $NS 2>&1 | grep -E -- '--- (PASS|FAIL)|^ok|FAIL|error|Pushing|Successfully' 
for i in $(seq 1 30); do PH=$(oc get $B -n $NS -o jsonpath='{.status.phase}'); case $PH in Complete|Failed|Error|Cancelled) break;; esac; sleep 5; done
[ "$PH" = Complete ] || die "Router build $PH. See: oc logs $B -n $NS"
echo "ROUTER IMAGE: built and pushed (plugin tests passed)"
