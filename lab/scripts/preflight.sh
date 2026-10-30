#!/usr/bin/env bash
# Preflight for the hetero-pd-decider lab. Read-only.
set -uo pipefail
hr() { printf '\n==== %s ====\n' "$1"; }

hr "Tools"
for t in oc helm podman git python3; do
  printf '%-8s ' "$t"; command -v "$t" >/dev/null && "$t" version 2>/dev/null | head -1 || echo "MISSING"
done

hr "Cluster"
oc whoami 2>&1; oc whoami --show-server 2>&1
oc version 2>&1 | head -3
oc auth can-i '*' '*' --all-namespaces 2>&1 | sed 's/^/cluster-admin: /'

hr "Nodes and accelerators"
oc get nodes -o custom-columns='NAME:.metadata.name,NV_PRODUCT:.metadata.labels.nvidia\.com/gpu\.product,NV_GPU:.status.allocatable.nvidia\.com/gpu,GAUDI:.status.allocatable.habana\.ai/gaudi,IP:.status.addresses[0].address'

hr "Accelerator node labels"
oc get nodes -o json | python3 -c '
import json,sys
for n in json.load(sys.stdin)["items"]:
    l={k:v for k,v in n["metadata"]["labels"].items() if any(s in k for s in ("nvidia.com/gpu","habana","gaudi","pci-1da3","pci-10de"))}
    if l:
        print(n["metadata"]["name"])
        for k,v in sorted(l.items()): print("   ",k,"=",v)
'

hr "Operators (CSVs)"
oc get csv -A 2>/dev/null | grep -Ei 'gpu-operator|habana|gaudi|intel|nfd|node-feature' || echo "none matched"

hr "Device plugin / operator pods"
oc get pods -A 2>/dev/null | grep -Ei 'nvidia|habana|gaudi' | head -30 || true

hr "Gateway API / InferencePool CRDs"
oc get crd 2>/dev/null | grep -Ei 'inferencepool|inferencemodel|gateway\.networking' || echo "none found"

hr "Storage classes"
oc get sc 2>&1

hr "Existing lab namespace"
oc get ns hetero-pd-lab 2>&1
