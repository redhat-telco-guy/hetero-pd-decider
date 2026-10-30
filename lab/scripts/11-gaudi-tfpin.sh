#!/usr/bin/env bash
# Gaudi crash fix: pin transformers in the Gaudi image to the version the A30 image ships.
set -uo pipefail
NS=hetero-pd-lab; W1=worker1.ai154.dl154.dfw.ocp.run; W2=worker2.ai154.dl154.dfw.ocp.run
IMG=image-registry.openshift-image-registry.svc:5000/$NS/vllm-gaudi-nixl
REPO=$(cd "$(dirname "$0")/../.." && pwd)
hr() { printf '\n==== %s ====\n' "$1"; }
oc whoami >/dev/null 2>&1 || { echo "Cannot reach cluster; reconnect and oc login, then re-run."; exit 1; }

pyver() {  # pyver <image> <node> <pkg...> -> "pkg==ver" lines, from a throwaway pod
  local name=pv-$RANDOM img=$1 node=$2; shift 2
  oc run $name -n $NS --rm -i --quiet --restart=Never --image="$img" --command \
    --overrides="{\"spec\":{\"serviceAccountName\":\"hetero-pd\",\"nodeSelector\":{\"kubernetes.io/hostname\":\"$node\"}}}" \
    -- python3 -c "import importlib.metadata as m,sys
for p in sys.argv[1:]:
    try: print(f'{p}=={m.version(p)}')
    except Exception: print(f'{p}==MISSING')" "$@" 2>&1 | grep '=='
}

hr "Package versions: A30 image (reference) vs Gaudi image"
PKGS="transformers tokenizers huggingface-hub safetensors"
A=$(pyver docker.io/vllm/vllm-openai:v0.26.0 $W1 $PKGS vllm)
G=$(pyver $IMG:v0.26.0 $W2 $PKGS vllm vllm_gaudi)
echo "A30:   " $A; echo "Gaudi: " $G
echo "$A" | grep -q MISSING && { echo "Could not read a package version from the A30 image; stopping."; exit 1; }
PINS=$(echo "$A" | grep -v '^vllm==' | sed 's/.*/"&"/' | tr '\n' ' ')
[ -n "$PINS" ] || { echo "No pins read; stopping."; exit 1; }

hr "Build $IMG:v0.26.0-tfpin with: $PINS"
oc delete bc vllm-gaudi-tfpin -n $NS --ignore-not-found >/dev/null
oc apply -n $NS -f - <<YAML
apiVersion: build.openshift.io/v1
kind: BuildConfig
metadata: {name: vllm-gaudi-tfpin}
spec:
  nodeSelector: {kubernetes.io/hostname: $W2}
  source:
    dockerfile: |
      FROM $IMG:v0.26.0
      RUN pip install --no-cache-dir --no-deps $PINS && \
          python3 -c "from transformers.models.pixtral.modeling_pixtral import PixtralRotaryEmbedding; import transformers; print('transformers', transformers.__version__, 'import OK')"
  strategy: {type: Docker}
  output: {to: {kind: ImageStreamTag, name: "vllm-gaudi-nixl:v0.26.0-tfpin"}}
YAML
B=$(oc start-build vllm-gaudi-tfpin -n $NS -o name); oc logs -f $B -n $NS 2>&1 | grep -vE '^Copying blob|^Getting image|^Writing manifest' | tail -15
for i in $(seq 1 20); do PH=$(oc get $B -n $NS -o jsonpath='{.status.phase}'); case $PH in Complete|Failed|Error|Cancelled) break;; esac; sleep 5; done
[ "$PH" = Complete ] || { echo "PIN BUILD FAILED (phase=$PH)"; exit 1; }
echo "PIN BUILD: SUCCESS"

hr "Roll out decode-gaudi3 with the pinned image; clear the old A30 pod"
oc apply -n $NS -k $REPO/lab/modelserver/layout-a-a30-prefill
oc rollout restart deploy/decode-gaudi3 -n $NS
oc delete pod -n $NS -l app=prefill-a30 --field-selector=status.phase!=Running --ignore-not-found >/dev/null
echo "Now run: bash lab/scripts/10-deploy-layout-a.sh   (it waits for both engines and smoke-tests them)"
