#!/usr/bin/env bash
# Read-only: copy everything worth keeping from the lab cluster to this laptop before it is rebuilt.
# Output: lab-archive/<date>/  (results, configs, versions, metrics, logs) + a .tgz of it.
set -uo pipefail
NS=hetero-pd-lab; REPO=$(cd "$(dirname "$0")/../.." && pwd)
D=$REPO/lab-archive/$(date +%Y-%m-%d); mkdir -p $D/{results,cluster,operators,lab,router,modelservers,metrics,logs,gpu}
hr() { printf '\n==== %s ====\n' "$1"; }
oc whoami >/dev/null 2>&1 || { echo "Cannot reach the cluster. Reconnect, run oc login, then re-run."; exit 1; }
run() { local f=$1; shift; "$@" > "$f" 2>&1 || echo "  (failed: $*)" ; echo "  $(basename $f): $(wc -c < "$f" | tr -d ' ') bytes"; }
DASH=$(oc get pod -n $NS -l app=hetero-pd-dashboard -o name 2>/dev/null | head -1); [ -z "$DASH" ] && DASH=deploy/hetero-pd-dashboard
fetch() { # fetch URL from inside the dashboard pod (cluster network; auth=1 adds the service-account token)
  oc exec -n $NS $DASH -- python3 -c "
import sys,urllib.request,ssl
r=urllib.request.Request(sys.argv[1])
if sys.argv[2]=='1': r.add_header('Authorization','Bearer '+open('/var/run/secrets/kubernetes.io/serviceaccount/token').read().strip())
print(urllib.request.urlopen(r,timeout=20).read().decode())" "$1" "${2:-0}"; }

hr "1. Test results (every run the dashboard saved)"
run $D/results/history.json oc get configmap hetero-pd-dashboard-results -n $NS -o jsonpath='{.data.history\.json}'
run $D/results/dashboard-state.json fetch http://localhost:8080/api/state
cp $REPO/suite-results*.json $REPO/decisions-auto2.log $D/results/ 2>/dev/null
python3 -c "import json,collections;d=json.load(open('$D/results/history.json'));print('  runs:',len(d),dict(collections.Counter(r['mode'] for r in d)))"

hr "2. Cluster and nodes"
run $D/cluster/version.txt oc version
run $D/cluster/clusterversion.yaml oc get clusterversion -o yaml
run $D/cluster/nodes-wide.txt oc get nodes -o wide --show-labels
run $D/cluster/nodes.yaml oc get nodes -o yaml
for n in $(oc get nodes -o name); do oc describe $n > $D/cluster/describe-$(basename $n).txt 2>&1; done; echo "  node descriptions: $(ls $D/cluster/describe-* | wc -l)"

hr "3. Operators (NFD, NVIDIA, Intel Gaudi, KMM)"
run $D/operators/csv.txt oc get csv -A -o wide
run $D/operators/subscriptions.yaml oc get subscriptions.operators.coreos.com -A -o yaml
run $D/operators/nvidia-clusterpolicy.yaml oc get clusterpolicies.nvidia.com -o yaml
run $D/operators/gaudi-clusterpolicy.yaml oc get clusterpolicies.habanalabs.habana.ai -o yaml
run $D/operators/nfd.yaml oc get nodefeaturediscoveries.nfd.openshift.io -A -o yaml
for ns in nvidia-gpu-operator habana-ai-operator openshift-nfd openshift-kmm; do run $D/operators/pods-$ns.txt oc get pods -n $ns -o wide; done

hr "4. Lab namespace ($NS); secrets are listed by name only, never their values"
for k in deployments services routes configmaps buildconfigs imagestreams serviceaccounts roles rolebindings; do run $D/lab/$k.yaml oc get $k -n $NS -o yaml; done
run $D/lab/pods.txt oc get pods -n $NS -o wide
run $D/lab/builds.txt oc get builds -n $NS
run $D/lab/secrets-names.txt oc get secrets -n $NS
run $D/lab/events.txt oc get events -n $NS --sort-by=.lastTimestamp
run $D/lab/scc.txt oc get scc anyuid -o yaml

hr "5. Router (llm-d EPP + your plugin)"
run $D/router/helm-list.txt helm list -n $NS
run $D/router/helm-values.yaml helm get values hetero-pd -n $NS --all
run $D/router/helm-manifest.yaml helm get manifest hetero-pd -n $NS
run $D/router/epp-deployment.yaml oc get deploy hetero-pd-epp -n $NS -o yaml
run $D/router/epp-metrics.txt fetch http://hetero-pd-epp.$NS.svc:9090/metrics 1
run $D/logs/epp.log oc logs -n $NS deploy/hetero-pd-epp -c epp --tail=5000
oc logs -n $NS deploy/hetero-pd-epp -c epp --tail=20000 2>/dev/null | grep 'hetero-pd-decider decision' > $D/logs/epp-decisions.log; echo "  decision log lines: $(wc -l < $D/logs/epp-decisions.log)"

hr "6. Model servers (vLLM): version, model, metrics, startup logs"
oc get pods -n $NS -l llm-d.ai/guide=hetero-pd -o jsonpath='{range .items[*]}{.metadata.name} {.status.podIP}{"\n"}{end}' | while read p ip; do
  [ -z "$ip" ] && continue
  for port in 8200 8000; do v=$(fetch http://$ip:$port/version 2>/dev/null) && break; done
  echo "$v" > $D/modelservers/$p-version.json
  fetch http://$ip:$port/v1/models > $D/modelservers/$p-models.json 2>&1
  fetch http://$ip:$port/metrics > $D/metrics/$p-vllm-metrics.txt 2>&1
  oc get pod $p -n $NS -o yaml > $D/modelservers/$p-pod.yaml
  for c in $(oc get pod $p -n $NS -o jsonpath='{.spec.containers[*].name}'); do oc logs -n $NS $p -c $c --tail=3000 > $D/logs/$p-$c.log 2>&1; done
  echo "  $p ($ip, port $port): vLLM $(echo "$v" | tr -d '\n' | cut -c1-60)"
done

hr "7. GPU cards: NVIDIA A30 (nvidia-smi) and Intel Gaudi (metric exporter)"
for p in $(oc get pods -n nvidia-gpu-operator -o name | grep -E 'driver-daemonset'); do
  node=$(oc get -n nvidia-gpu-operator $p -o jsonpath='{.spec.nodeName}')
  oc exec -n nvidia-gpu-operator $p -- nvidia-smi > $D/gpu/nvidia-smi-$node.txt 2>&1
  oc exec -n nvidia-gpu-operator $p -- nvidia-smi -q > $D/gpu/nvidia-smi-q-$node.txt 2>&1
  echo "  nvidia-smi from $node"
done
EP=$(oc get pods -n habana-ai-operator -o name | grep metric-exporter | head -1)
if [ -n "$EP" ]; then PORT=$(oc get -n habana-ai-operator $EP -o jsonpath='{.spec.containers[0].ports[0].containerPort}')
  oc get --raw "/api/v1/namespaces/habana-ai-operator/pods/$(basename $EP):$PORT/proxy/metrics" > $D/gpu/gaudi-metrics.txt 2>&1; echo "  Gaudi metrics: $(wc -l < $D/gpu/gaudi-metrics.txt) lines"; fi
oc debug node/worker2.ai154.dl154.dfw.ocp.run -q -- chroot /host sh -c 'lspci -nn -d 1da3:; dmesg -T | grep -i habanalabs' > $D/gpu/gaudi-worker2-dmesg.txt 2>&1
cp $REPO/gaudi-worker2-evidence.txt $REPO/33-gaudi-*.txt $D/gpu/ 2>/dev/null

hr "8. Earlier script outputs and dashboard page"
mkdir -p $D/script-outputs; cp $REPO/[0-9][0-9]-*.txt $REPO/hw.txt $REPO/preflight.txt $REPO/install-v*.txt $D/script-outputs/ 2>/dev/null; echo "  $(ls $D/script-outputs | wc -l) files"
cp $REPO/lab/dashboard2/web/index.html $D/lab/dashboard-index.html

hr "9. Pack"
cd $REPO/lab-archive && tar czf hetero-pd-lab-$(basename $D).tgz $(basename $D) && ls -lh hetero-pd-lab-$(basename $D).tgz
du -sh $D; echo "Archive folder: $D"
