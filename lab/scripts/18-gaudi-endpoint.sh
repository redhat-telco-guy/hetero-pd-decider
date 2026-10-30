#!/usr/bin/env bash
NS=hetero-pd-lab
G=$(oc get pod -n $NS -l app=decode-gaudi3 -o jsonpath='{.items[0].status.podIP}')
A=$(oc get pod -n $NS -l app=prefill-a30 -o jsonpath='{.items[0].status.podIP}')
echo "gaudi=$G a30=$A"
echo "==== Timing from inside the cluster (same path the router uses) ===="
oc run curlprobe -n $NS --rm -i --quiet --restart=Never --image=registry.access.redhat.com/ubi9/ubi:latest --command -- bash -c "
for u in http://$G:8000/metrics http://$G:8200/metrics http://$A:8000/metrics http://$G:8000/v1/models; do
  printf '%-40s ' \$u; curl -s -o /tmp/o -m 15 -w 'HTTP %{http_code} %{time_total}s ' \$u; wc -c </tmp/o
done
echo '--- Gaudi vllm metric names (first 15)'; curl -s -m 15 http://$G:8200/metrics | grep -E '^vllm:(num_requests|kv_cache|gpu_cache|cache_config)' | head -15
echo '--- A30 vllm metric names (first 15)';   curl -s -m 15 http://$A:8000/metrics | grep -E '^vllm:(num_requests|kv_cache|gpu_cache|cache_config)' | head -15
" 2>&1
echo "==== Router log lines about the Gaudi pod (excluding the scrape timeouts) ===="
oc logs -n $NS deploy/hetero-pd-epp -c epp 2>/dev/null | grep -E "decode-gaudi3|$G" | grep -v 'context deadline exceeded' | tail -15 | cut -c1-500
echo "==== Is the scrape still failing now? ===="
oc logs -n $NS deploy/hetero-pd-epp -c epp --since=60s 2>/dev/null | grep -c 'dispatch failed'
echo "==== Router log: first request of the correctness run, all lines ===="
RID=$(oc logs -n $NS deploy/hetero-pd-epp -c epp 2>/dev/null | grep 'EPP received request' | head -1 | python3 -c "import sys,json;print(json.loads(sys.stdin.read())['x-request-id'])")
oc logs -n $NS deploy/hetero-pd-epp -c epp 2>/dev/null | grep "$RID" | python3 -c "
import sys,json
for l in sys.stdin:
    d=json.loads(l); keep={k:v for k,v in d.items() if k not in ('stacktrace','service.name','x-request-id','eppRequestID','objectiveKey','incomingModelName','targetModelName','priority','severity_number','timestamp')}
    print(json.dumps(keep)[:400])"
