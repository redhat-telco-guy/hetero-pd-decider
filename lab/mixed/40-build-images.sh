#!/usr/bin/env bash
# Mixed lab, part 1: namespace + both images, built inside the cluster.
#   - router (llm-d EPP) with hetero-pd-decider, built on an A30 node (~15 min)
#   - vLLM for Gaudi (vllm-gaudi v0.26.0 + NIXL), built on the Gaudi node (long: 1-2 h),
#     then transformers pinned to the A30 image's version (fix from the first lab)
#   bash lab/mixed/40-build-images.sh 2>&1 | tee 40-build-images.txt
set -uo pipefail
A=$(cd "$(dirname "$0")" && pwd); REPO=$(cd "$A/../.." && pwd); NS=hetero-pd-lab
IMG=image-registry.openshift-image-registry.svc:5000/$NS/vllm-gaudi-nixl
hr() { printf '\n==== %s ====\n' "$1"; }
oc whoami >/dev/null 2>&1 || { echo "Not logged in. Run oc login first."; exit 1; }
GNODE=$(oc get nodes -l feature.node.kubernetes.io/pci-1da3.present=true -o jsonpath='{.items[0].metadata.name}')
ANODE=$(oc get nodes -l nvidia.com/gpu.product=NVIDIA-A30 -o jsonpath='{.items[0].metadata.name}')
[ -n "$GNODE" ] && [ -n "$ANODE" ] || { echo "Need an A30 node and a Gaudi node; run lab/scripts/37-gpu-operators.sh first."; exit 1; }
echo "A30 node: $ANODE   Gaudi node: $GNODE"

hr "1. Namespace, Hugging Face token, service account"
bash $REPO/lab/a30-only/03-namespace.sh 2>&1 | grep -vE '^$'

hr "2. Gaudi vLLM build (starts first, runs on $GNODE in the background)"
oc apply -n $NS -f - <<YAML
apiVersion: image.openshift.io/v1
kind: ImageStream
metadata: {name: vllm-gaudi-nixl}
---
apiVersion: build.openshift.io/v1
kind: BuildConfig
metadata: {name: vllm-gaudi-nixl}
spec:
  nodeSelector: {kubernetes.io/hostname: $GNODE}
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
if oc get istag vllm-gaudi-nixl:v0.26.0 -n $NS >/dev/null 2>&1; then echo "  Gaudi base image already built"
elif oc get builds -n $NS -l buildconfig=vllm-gaudi-nixl -o jsonpath='{.items[*].status.phase}' | grep -qE 'New|Pending|Running'; then echo "  Gaudi build already running"
else GB=$(oc start-build vllm-gaudi-nixl -n $NS -o name); echo "  started $GB"; fi

hr "3. Router image with your plugin (on $ANODE, ~15 min; plugin tests run here)"
if oc get istag llm-d-router-endpoint-picker:hetero-pd-dev -n $NS >/dev/null 2>&1 && [ "${REBUILD_ROUTER:-0}" = 0 ]; then echo "  router image already built (REBUILD_ROUTER=1 to rebuild)"
else bash $REPO/lab/a30-only/04-router-image.sh 2>&1 | grep -E -- '--- (PASS|FAIL)|^ok|FAIL|ROUTER IMAGE|STOP|Building at'; fi
oc get istag llm-d-router-endpoint-picker:hetero-pd-dev -n $NS >/dev/null 2>&1 || { echo "Router image missing; stopping."; exit 1; }

hr "4. Waiting for the Gaudi vLLM build (checks every 2 min, up to 3 h)"
for i in $(seq 1 90); do
  oc get istag vllm-gaudi-nixl:v0.26.0 -n $NS >/dev/null 2>&1 && { echo "  Gaudi base image: built"; break; }
  B=$(oc get builds -n $NS -l buildconfig=vllm-gaudi-nixl --sort-by=.metadata.creationTimestamp -o name | tail -1)
  PH=$(oc get $B -n $NS -o jsonpath='{.status.phase}' 2>/dev/null)
  case "$PH" in Failed|Error|Cancelled) echo "  Gaudi build $PH. Last log lines:"; oc logs $B -n $NS --tail=30 2>&1 | cut -c1-200; exit 1;; esac
  echo "  [$(date +%H:%M)] $B $PH | $(oc logs $B -n $NS --tail=1 2>/dev/null | cut -c1-120)"
  sleep 120
done
oc get istag vllm-gaudi-nixl:v0.26.0 -n $NS >/dev/null 2>&1 || { echo "Gaudi build did not finish in 3 h; re-run this script to keep waiting."; exit 1; }

hr "5. Pin transformers in the Gaudi image to the A30 image's version (first-lab crash fix)"
pyver() { local name=pv-$RANDOM img=$1 node=$2; shift 2
  oc run $name -n $NS --rm -i --quiet --restart=Never --image="$img" --command \
    --overrides="{\"spec\":{\"serviceAccountName\":\"hetero-pd\",\"nodeSelector\":{\"kubernetes.io/hostname\":\"$node\"}}}" \
    -- python3 -c "import importlib.metadata as m,sys
for p in sys.argv[1:]:
    try: print(f'{p}=={m.version(p)}')
    except Exception: print(f'{p}==MISSING')" "$@" 2>&1 | grep '=='; }
# The versions the A30 image (vllm-openai v0.26.0) ships, read on the first lab. Used when the A30 image
# cannot be read here (first pull of the ~10 GB image is slower than the throwaway pod waits).
KNOWN='"transformers==5.14.1" "tokenizers==0.22.2" "huggingface-hub==1.24.0" "safetensors==0.8.0"'
if oc get istag vllm-gaudi-nixl:v0.26.0-tfpin -n $NS >/dev/null 2>&1 && oc logs bc/vllm-gaudi-tfpin -n $NS 2>/dev/null | grep -q 'transformers 5.14'; then
  echo "  pinned image already built ($(oc logs bc/vllm-gaudi-tfpin -n $NS 2>/dev/null | grep -m1 'transformers 5.14'))"
else
  PK="transformers tokenizers huggingface-hub safetensors"
  AV=$(pyver docker.io/vllm/vllm-openai:v0.26.0 $ANODE $PK); echo "  A30 image: " ${AV:-not readable}
  if echo "$AV" | grep -q '^transformers==' && ! echo "$AV" | grep -q MISSING; then PINS=$(echo "$AV" | sed 's/.*/"&"/' | tr '\n' ' ')
  else PINS=$KNOWN; echo "  using the versions read on the first lab"; fi
  echo "  pins: $PINS"
  oc delete bc vllm-gaudi-tfpin -n $NS --ignore-not-found >/dev/null
  oc apply -n $NS -f - <<YAML
apiVersion: build.openshift.io/v1
kind: BuildConfig
metadata: {name: vllm-gaudi-tfpin}
spec:
  nodeSelector: {kubernetes.io/hostname: $GNODE}
  source:
    dockerfile: |
      FROM $IMG:v0.26.0
      RUN pip install --no-cache-dir --no-deps $PINS && python3 -c "import transformers; print('transformers', transformers.__version__)"
  strategy: {type: Docker}
  output: {to: {kind: ImageStreamTag, name: "vllm-gaudi-nixl:v0.26.0-tfpin"}}
YAML
  B=$(oc start-build vllm-gaudi-tfpin -n $NS -o name)
  for i in $(seq 1 120); do PH=$(oc get $B -n $NS -o jsonpath='{.status.phase}'); case $PH in Complete|Failed|Error|Cancelled) break;; esac; sleep 10; done
  [ "$PH" = Complete ] || { echo "Pin build $PH:"; oc logs $B -n $NS --tail=20; exit 1; }
  V=$(oc logs $B -n $NS 2>/dev/null | grep -m1 '^transformers ')
  case "$V" in "transformers 5.14"*) echo "  verified: $V";; *) echo "Pinned image does not report transformers 5.14 (got: ${V:-nothing}); stopping."; exit 1;; esac
fi
hr "Images ready"
oc get istag -n $NS
echo; echo "Next: bash lab/mixed/41-deploy.sh 2>&1 | tee 41-deploy.txt"
