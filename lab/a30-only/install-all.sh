#!/usr/bin/env bash
# Build the whole A30-only lab, step by step. Stops at the first step that fails; re-running is safe.
#   bash lab/a30-only/install-all.sh 2>&1 | tee a30-install.txt
A=$(cd "$(dirname "$0")" && pwd)
for s in 00-preflight 01-operators 02-gpus 03-namespace 04-router-image 05-model-servers 06-router 07-dashboard 08-check; do
  printf '\n######## %s ########\n' $s
  bash $A/$s.sh || { echo; echo "Stopped at $s. Fix the issue above and re-run install-all.sh (finished steps are skipped or repeated safely)."; exit 1; }
done
echo; echo "A30-only lab is ready. Optional: bash lab/scripts/35-restore-history.sh <saved history.json> --merge"
