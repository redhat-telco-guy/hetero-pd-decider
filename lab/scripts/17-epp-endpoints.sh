#!/usr/bin/env bash
# What endpoints does the router see, and which filter drops them?
NS=hetero-pd-lab
E() { oc logs -n $NS deploy/hetero-pd-epp -c epp "$@" 2>/dev/null; }
echo "==== EPP args ===="; oc get deploy hetero-pd-epp -n $NS -o jsonpath='{range .spec.template.spec.containers[?(@.name=="epp")].args[*]}{@}{" "}{end}{"\n"}'
echo "==== Endpoint discovery lines (startup) ===="
E | grep -iE 'endpoint|pod ' | grep -viE 'x-request-id|scrape' | head -25 | cut -c1-500
echo "==== Last 'Filter eliminated' line in full ===="
E | grep 'Filter eliminated' | tail -1 | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); [print(f'{k}: {v}') for k,v in d.items() if k not in ('stacktrace',)]"
echo "==== Last 'Running filter plugin' line in full ===="
E | grep 'Running filter plugin' | tail -1 | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); [print(f'{k}: {v}') for k,v in d.items()]"
echo "==== RBAC: can the EPP service account list pods? ===="
SA=$(oc get deploy hetero-pd-epp -n $NS -o jsonpath='{.spec.template.spec.serviceAccountName}'); echo "sa=$SA"
oc auth can-i list pods -n $NS --as=system:serviceaccount:$NS:$SA
oc auth can-i watch pods -n $NS --as=system:serviceaccount:$NS:$SA
echo "==== Plugin state endpoint ===="
oc exec -n $NS deploy/hetero-pd-epp -c epp -- /app/epp --help >/dev/null 2>&1
oc port-forward -n $NS deploy/hetero-pd-epp 19090:9090 >/dev/null 2>&1 & PF=$!; sleep 4
curl -s -m 5 localhost:19090/debug/plugins/state | head -c 1500; echo
curl -s -m 5 localhost:19090/metrics | grep -iE '^(llm_d_epp|inference_pool|inference_objective).*(endpoint|pod|ready)' | head -15
kill $PF 2>/dev/null
