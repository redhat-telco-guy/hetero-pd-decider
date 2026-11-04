#!/usr/bin/env bash
# Three vLLM servers on three NVIDIA generations: prefill-t4, prefill-a10g, decode-l4.
#   CONFIG=lab/aws-nvidia/config.env bash lab/aws-nvidia/05-aws-model-servers.sh
export CONFIG=${CONFIG:-$(cd "$(dirname "$0")" && pwd)/config.env}
source "$(dirname "$0")/../a30-only/lib.sh"; login
H=$REPO/lab/aws-nvidia
hr "Free GPUs per type (Dual-Key's model servers may be using them)"
for p in $T4_PRODUCT $A10G_PRODUCT $L4_PRODUCT; do
  n=$(oc get nodes -l nvidia.com/gpu.product=$p -o name | wc -l | tr -d ' ')
  used=$(oc get pods -A -o jsonpath='{range .items[?(@.status.phase=="Running")]}{.metadata.namespace}{" "}{.spec.nodeName}{" "}{.spec.containers[*].resources.limits.nvidia\.com/gpu}{"\n"}{end}' \
         | awk -v ns="$NS" -v nodes="$(oc get nodes -l nvidia.com/gpu.product=$p -o jsonpath='{.items[*].metadata.name}')" 'BEGIN{split(nodes,a," ");for(i in a)m[a[i]]=1} $1!=ns && m[$2]{for(i=3;i<=NF;i++)s+=$i} END{print s+0}')
  tot=$(oc get nodes -l nvidia.com/gpu.product=$p -o jsonpath='{range .items[*]}{.status.allocatable.nvidia\.com/gpu}{"\n"}{end}' | awk '{s+=$1} END{print s+0}')
  echo "  $p: $n node(s), $tot GPU(s), $used used by others (not counting this lab)"
  [ "$tot" -ge 1 ] || die "No $p GPU. Check the product label: oc get nodes -L nvidia.com/gpu.product"
  [ "$used" -lt "$tot" ] || die "Every $p GPU is in use. Scale down Dual-Key's model servers on it first (see lab/aws-nvidia/README.md)."
done
BE=""; [ -n "${BACKEND:-}" ] && BE="\"--attention-backend=$BACKEND\", "
hr "Deploy (model $MODEL, attention backend: ${BACKEND:-default for each card})"
sed "s#__MODEL__#$MODEL#g; s#__T4_PRODUCT__#$T4_PRODUCT#; s#__A10G_PRODUCT__#$A10G_PRODUCT#; s#__L4_PRODUCT__#$L4_PRODUCT#; s#__BACKEND_ARG__#$BE#g" \
  $H/model-servers.yaml | oc apply -n $NS -f -
sleep 15   # on a re-run, let the old pods stop first (Recreate), so "ready" means the new ones
hr "Waiting for all three (up to 20 min)"
for i in $(seq 1 80); do
  line=""; ready=0
  for d in prefill-t4 prefill-a10g decode-l4; do r=$(oc get deploy $d -n $NS -o jsonpath='{.status.readyReplicas}'); line="$line $d=${r:-0}"; [ "${r:-0}" -ge 1 ] && ready=$((ready+1)); done
  echo "  [$i $(date +%H:%M)]$line"; [ $ready -eq 3 ] && break
  oc get pods -n $NS -l llm-d.ai/guide=hetero-pd --no-headers | grep -E 'CrashLoop|ImagePull|Error' && die "A model server failed; see: oc logs -n $NS deploy/<name> -c modelserver"
  sleep 15
done
[ $ready -eq 3 ] || die "Not all model servers became ready."
hr "Attention backend each server chose"
PAT='Using [A-Za-z0-9_.]+( attention)? backend'
for d in prefill-t4 prefill-a10g decode-l4; do
  b=$(oc logs -n $NS deploy/$d -c modelserver 2>/dev/null | grep -oiE "$PAT" | tail -1)
  printf "  %-13s %s\n" "$d" "${b:-(not found in log)}"
done
