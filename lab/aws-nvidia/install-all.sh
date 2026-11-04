#!/usr/bin/env bash
# Build the NVIDIA mixed-generation lab (T4 + A10G + L4) on OpenShift on AWS.
#   oc login ... (the AWS cluster)
#   bash lab/aws-nvidia/install-all.sh 2>&1 | tee aws-install.txt
# Reuses the lab/a30-only steps with lab/aws-nvidia/config.env. Installs NFD and the NVIDIA GPU
# Operator if the cluster has none yet. Stops at the first failing step; re-running is safe.
H=$(cd "$(dirname "$0")" && pwd); REPO=$(cd "$H/../.." && pwd)
export CONFIG=$H/config.env; source $CONFIG
export BUILD_CPU BUILD_MEM
step() { printf '\n######## %s ########\n' "$1"; shift; "$@" || { echo; echo "Stopped at this step. Fix the issue above and re-run."; exit 1; }; }
step "preflight"              bash $REPO/lab/a30-only/00-preflight.sh
# New cluster without the NVIDIA GPU Operator: install NFD + the operator and wait for the GPUs.
if ! oc get clusterpolicies.nvidia.com -o name 2>/dev/null | grep -q .; then
  step "GPU operators (new cluster)" bash $REPO/lab/a30-only/01-operators.sh
  step "GPU drivers (10-25 min)"     bash $REPO/lab/a30-only/02-gpus.sh
fi
step "namespace + HF token"   bash $REPO/lab/a30-only/03-namespace.sh
step "router image (plugin)"  bash $REPO/lab/a30-only/04-router-image.sh
step "model servers"          bash $H/05-aws-model-servers.sh
step "compatibility keys"     bash $REPO/lab/compat/60-compat-install.sh $NS
step "measure prefill speeds" bash $H/72-measure-profiles.sh
step "router"                 env MODES_VALUES=$H/modes.values.aws.yaml bash $REPO/lab/a30-only/06-router.sh
step "dashboard"              bash $REPO/lab/a30-only/07-dashboard.sh
echo; echo "AWS lab ready. Next: the test plan in lab/aws-nvidia/README.md (validate pairs with lab/compat/61-validate-pair.sh)."
