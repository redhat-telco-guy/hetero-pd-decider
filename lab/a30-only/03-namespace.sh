#!/usr/bin/env bash
# Lab namespace, Hugging Face token secret, and the service account the vLLM pods run as.
source "$(dirname "$0")/lib.sh"; login
hr "Namespace $NS"
oc get ns $NS >/dev/null 2>&1 || oc new-project $NS >/dev/null; echo "  ready"
hr "Hugging Face token (secret llm-d-hf-token)"
if oc get secret llm-d-hf-token -n $NS >/dev/null 2>&1; then echo "  already present"
else
  [ -z "${HF_TOKEN:-}" ] && { printf "  Paste your Hugging Face token (hidden), then Enter: "; read -rs HF_TOKEN; echo; }
  [ -n "$HF_TOKEN" ] || die "A Hugging Face token is needed to download the model."
  oc create secret generic llm-d-hf-token --from-literal=HF_TOKEN="$HF_TOKEN" -n $NS >/dev/null && echo "  created"
fi
hr "Service account + anyuid"
# Workaround: the vLLM images write under /root, which the default restricted SCC does not allow.
oc apply -n $NS -f $REPO/lab/modelserver/common/serviceaccount.yaml
oc adm policy add-scc-to-user anyuid -z hetero-pd -n $NS
