# Shared helpers for the A30-only installer. Sourced by every step.
set -uo pipefail
A=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd); REPO=$(cd "$A/../.." && pwd)
source "${CONFIG:-$A/config.env}"   # CONFIG=<file> reuses these steps for another lab (lab/aws-nvidia)
hr()   { printf '\n==== %s ====\n' "$1"; }
die()  { echo "STOP: $*"; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "'$1' is not installed on this computer."; }
login(){ oc whoami >/dev/null 2>&1 || die "Not logged in. Run: oc login --token=... --server=https://api.<cluster>:6443"; }
# Nodes with A30 cards (after the NVIDIA operator labels them), and NVIDIA nodes before that (NFD PCI label).
a30_nodes()    { oc get nodes -l nvidia.com/gpu.product=$A30_PRODUCT -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'; }
nvidia_nodes() { oc get nodes -l feature.node.kubernetes.io/pci-10de.present=true -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'; }
a30_total()    { local t=0 n; for n in $(a30_nodes); do t=$((t + $(oc get node $n -o jsonpath='{.status.allocatable.nvidia\.com/gpu}' 2>/dev/null || echo 0))); done; echo $t; }
first_a30()    { a30_nodes | head -1; }
