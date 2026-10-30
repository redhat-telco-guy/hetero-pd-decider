#!/usr/bin/env bash
# Check this computer's tools and the cluster before installing anything.
source "$(dirname "$0")/lib.sh"
hr "Tools on this computer"
for t in oc helm git python3; do need $t; printf '  %-8s %s\n' $t "$($t version 2>/dev/null | head -1 || $t --version | head -1)"; done
login; echo "  logged in as $(oc whoami) on $(oc whoami --show-server)"
hr "Cluster"
oc get clusterversion version -o jsonpath='  OpenShift {.status.desired.version}{"\n"}'
oc get nodes -o wide
hr "NVIDIA cards (PCI vendor 10de seen by Node Feature Discovery, if already installed)"
nvidia_nodes | sed 's/^/  /' || true
hr "Image registry (the router image is built in-cluster and pushed here)"
oc get configs.imageregistry.operator.openshift.io cluster -o jsonpath='  managementState={.spec.managementState}  storage={.spec.storage}{"\n"}'
oc get configs.imageregistry.operator.openshift.io cluster -o jsonpath='{.spec.managementState}' | grep -q Managed || echo "  WARNING: internal registry is not Managed; the router build needs it."
echo; echo "Preflight done."
