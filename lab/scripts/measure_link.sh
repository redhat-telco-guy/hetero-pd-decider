#!/usr/bin/env bash
# Measure TCP bandwidth between the A30 node and a Gaudi node with iperf3.
# The result is the decider's bandwidthGbps.
#
#   ./measure_link.sh <a30-node-name> <gaudi-node-name> [namespace]
#
# On OpenShift the iperf3 image may need an SCC that allows its user; if the
# pods fail to start, run: oc adm policy add-scc-to-user anyuid -z default -n <ns>
set -euo pipefail

A30_NODE=${1:?a30 node name}
GAUDI_NODE=${2:?gaudi node name}
NS=${3:-hetero-pd-lab}
IMAGE=${IPERF_IMAGE:-docker.io/networkstatic/iperf3:latest}

cleanup() { kubectl -n "$NS" delete pod iperf-server iperf-client --ignore-not-found --wait=false >/dev/null; }
trap cleanup EXIT

kubectl -n "$NS" run iperf-server --image="$IMAGE" --restart=Never \
  --overrides="{\"spec\":{\"nodeName\":\"$GAUDI_NODE\"}}" -- -s
kubectl -n "$NS" wait --for=condition=Ready pod/iperf-server --timeout=180s
SERVER_IP=$(kubectl -n "$NS" get pod iperf-server -o jsonpath='{.status.podIP}')

kubectl -n "$NS" run iperf-client --image="$IMAGE" --restart=Never \
  --overrides="{\"spec\":{\"nodeName\":\"$A30_NODE\"}}" -- -c "$SERVER_IP" -P 4 -t 15 -J
kubectl -n "$NS" wait --for=jsonpath='{.status.phase}'=Succeeded pod/iperf-client --timeout=180s

kubectl -n "$NS" logs iperf-client | python3 -c '
import json, sys
gbps = json.load(sys.stdin)["end"]["sum_received"]["bits_per_second"] / 1e9
print(f"measured: {gbps:.1f} Gbit/s (4 streams)")
print(f"set bandwidthGbps to about {gbps * 0.8:.0f}  (80% of measured, leaving room for other traffic)")
'
