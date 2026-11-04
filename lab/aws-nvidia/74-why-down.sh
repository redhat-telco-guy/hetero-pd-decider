#!/usr/bin/env bash
# Why did a model server go down? Restarts, last exit reason, the end of the log before the restart, events.
#   bash lab/aws-nvidia/74-why-down.sh 2>&1 | tee why-down.txt
NS=${NS:-hetero-pd-aws}
oc whoami >/dev/null 2>&1 || { echo "Not logged in. Run oc login first."; exit 1; }
echo "==== Restarts and last exit"
oc get pods -n $NS -l llm-d.ai/role -o custom-columns='POD:.metadata.name,RESTARTS:.status.containerStatuses[*].restartCount,CONTAINERS:.status.containerStatuses[*].name,LAST-EXIT:.status.containerStatuses[*].lastState.terminated.reason,EXIT-CODE:.status.containerStatuses[*].lastState.terminated.exitCode,AT:.status.containerStatuses[*].lastState.terminated.finishedAt'
for d in decode-l4 prefill-a10g prefill-t4; do
  for c in $(oc get deploy $d -n $NS -o jsonpath='{.spec.template.spec.containers[*].name}'); do
    if oc logs -n $NS deploy/$d -c $c --previous --tail=1 >/dev/null 2>&1; then
      echo; echo "==== $d / $c: last 40 lines before the restart"
      oc logs -n $NS deploy/$d -c $c --previous --tail=200 | grep -vE 'GET /metrics|GET /health' | tail -40
    fi
  done
done
echo; echo "==== Warning events (last hour)"
oc get events -n $NS --field-selector type=Warning --sort-by=.lastTimestamp 2>/dev/null | tail -15
echo; echo "==== Node memory/GPU pressure on the L4 node"
N=$(oc get pod -n $NS -l llm-d.ai/role=decode -o jsonpath='{.items[0].spec.nodeName}')
oc describe node $N | grep -E 'MemoryPressure|DiskPressure|Allocated resources' -A0
oc adm top pod -n $NS 2>/dev/null
