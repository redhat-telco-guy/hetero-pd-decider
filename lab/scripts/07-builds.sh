#!/usr/bin/env bash
# Step 1+2 of the runbook, in-cluster: router (EPP) image with the plugin, and vLLM for Gaudi.
set -uo pipefail
NS=hetero-pd-lab; W2=worker2.ai154.dl154.dfw.ocp.run
REPO=$(cd "$(dirname "$0")/../.." && pwd); KIT=$REPO/lab
hr() { printf '\n==== %s ====\n' "$1"; }
oc whoami >/dev/null 2>&1 || { echo "Cannot reach cluster; reconnect and oc login, then re-run."; exit 1; }
oc project -q $NS >/dev/null

hr "Optional: replace Hugging Face token (press Enter to keep the current one)"
printf "New HF token (hidden): "; read -rs T; echo
if [ -n "$T" ]; then
  oc create secret generic llm-d-hf-token --from-literal=HF_TOKEN="$T" -n $NS --dry-run=client -o yaml | oc apply -f - && echo "token replaced"
else echo "kept existing token"; fi
unset T

hr "Registry storage"
oc get pvc -n openshift-image-registry 2>&1

hr "Gaudi vLLM build (starts first, runs in background on worker2)"
oc apply -n $NS -f - <<YAML
apiVersion: image.openshift.io/v1
kind: ImageStream
metadata: {name: vllm-gaudi-nixl}
---
apiVersion: build.openshift.io/v1
kind: BuildConfig
metadata: {name: vllm-gaudi-nixl}
spec:
  nodeSelector: {kubernetes.io/hostname: $W2}
  runPolicy: Serial
  source:
    type: Git
    git: {uri: https://github.com/vllm-project/vllm-gaudi.git, ref: v0.26.0}
  strategy:
    type: Docker
    dockerStrategy:
      dockerfilePath: .cd/Dockerfile.ubuntu.pytorch.vllm.nixl.latest
      buildArgs:
        - {name: VLLM_GAUDI_COMMIT, value: v0.26.0}
        - {name: VLLM_PROJECT_COMMIT, value: v0.26.0}
  resources:
    requests: {cpu: "16", memory: 32Gi}
  output:
    to: {kind: ImageStreamTag, name: "vllm-gaudi-nixl:v0.26.0"}
YAML
if oc get builds -n $NS -l buildconfig=vllm-gaudi-nixl -o jsonpath='{.items[*].status.phase}' | grep -qE 'New|Pending|Running|Complete'; then
  echo "Gaudi build already started or done; not starting another."
else
  oc start-build vllm-gaudi-nixl -n $NS
fi

hr "Router (EPP) build with hetero-pd-decider: compile, vet, test (follows live, ~10-15 min)"
cp "$REPO/plugin/llm-d-patch/hetero-pd-decider.patch" "$KIT/build/epp/"
BASE=$(cat "$REPO/plugin/llm-d-patch/BASE_COMMIT")
oc get bc epp-hetero -n $NS >/dev/null 2>&1 || \
  oc new-build -n $NS --name=epp-hetero --strategy=docker --binary \
    --to=llm-d-router-endpoint-picker:hetero-pd-dev
echo "Router build moved to 08-epp-build.sh (binary builds ignore --build-arg)."
EPP_RC=1

hr "Result"
oc get builds -n $NS
oc get istag -n $NS 2>&1
echo "Run lab/scripts/08-epp-build.sh for the router image."
echo "Gaudi build is still running in the background; follow it with: oc logs -f bc/vllm-gaudi-nixl -n $NS"
