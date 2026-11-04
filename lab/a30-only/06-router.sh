#!/usr/bin/env bash
# Install the llm-d router (EPP + Envoy) with four switchable configs: your plugin (auto, default),
# stock llm-d, always-move, and the older strategies. Uses the llm-d chart at the pinned commit.
source "$(dirname "$0")/lib.sh"; login; need helm
BASE=$(tr -d '[:space:]' < $REPO/plugin/llm-d-patch/BASE_COMMIT); CH=$REPO/.cache/llm-d; NODE=$(first_a30)
[ -d $CH/.git ] || git clone -q https://github.com/llm-d/llm-d-inference-scheduler.git $CH
git -C $CH fetch -q origin 2>/dev/null; git -C $CH checkout -q $BASE || die "Cannot check out llm-d $BASE"
CHART=$CH/config/charts/llm-d-router-standalone
helm dependency build $CHART >/dev/null 2>&1 || helm dependency update $CHART >/dev/null
# Workaround: on the first lab, Envoy crash-looped on the Gaudi node; keep the router on an A30 node.
SITE=$(mktemp); cat > $SITE <<YAML
router:
  epp:
    affinity:
      nodeAffinity:
        requiredDuringSchedulingIgnoredDuringExecution:
          nodeSelectorTerms: [{matchExpressions: [{key: kubernetes.io/hostname, operator: In, values: ["$NODE"]}]}]
YAML
COMMON=$(mktemp); sed "s#svc:5000/hetero-pd-lab#svc:5000/$NS#" $REPO/lab/router/common.values.yaml > $COMMON   # router image lives in this namespace
MODES=${MODES_VALUES:-$REPO/lab/dashboard2/modes.values.yaml}   # MODES_VALUES=<file> for another lab's profiles
ARGS=(upgrade --install $RELEASE $CHART -n $NS -f $COMMON -f $MODES -f $SITE --wait --timeout 6m)
# Workaround: the dashboard's mode switch edits the router's --config-file arg; take it back on upgrade.
helm upgrade --help | grep -q -- --force-conflicts && ARGS+=(--force-conflicts)
hr "helm ${ARGS[*]:0:3} (pinned llm-d $BASE)"
helm "${ARGS[@]}" || die "Helm install failed."
rm -f $SITE $COMMON
oc rollout restart deploy/$RELEASE-epp -n $NS >/dev/null && oc rollout status deploy/$RELEASE-epp -n $NS --timeout=5m || die "Router did not start."
oc get deploy $RELEASE-epp -n $NS -o jsonpath='  router config: {.spec.template.spec.containers[?(@.name=="epp")].args}{"\n"}' | grep -o 'config-file","[^"]*' | sed 's/","/: /'
