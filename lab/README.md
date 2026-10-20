# Lab runbook: A30 + 2x Gaudi 3

This kit takes `hetero-pd-decider` from source to a measured A/B result on one NVIDIA A30 and two Intel Gaudi 3 cards on OpenShift.

| Folder | Contents |
| --- | --- |
| `../plugin/llm-d-patch/` | `hetero-pd-decider.patch` against llm-d-inference-scheduler at the commit in `BASE_COMMIT` |
| `router/` | Helm values: `common` (EPP image, pool selector) plus one decider each: `hetero`, `stock`, `always` |
| `modelserver/` | Kustomize layouts A, B and C (below) |
| `scripts/` | `profile_prefill.py`, `measure_link.sh`, `correctness.py`, `loadtest.py`, `compare.py`, `decisions.sh` |

## What the patch adds

| File | Purpose |
| --- | --- |
| `disagg/hetero/decide.go` | Decision math, standard library only. 98% test coverage. |
| `disagg/hetero_pd_decider.go` | llm-d plugin: config, prefill-pool view (`Produce`), decision hook, metric, logging |
| `disagg/metrics.go` | Adds `llm_d_epp_hetero_pd_decision_total{plugin_name,reason,remote_prefill}` |
| `cmd/epp/runner/runner.go` | Registers `hetero-pd-decider` (Alpha) |
| `deploy/config/hetero-pd-epp-config.yaml`, `disagg/README.md` | Sample config and plugin docs |

Verification status: `hetero/decide.go` and its tests were compiled and run (Go 1.24, all pass). The adapter and its tests were written against the scheduler source at `BASE_COMMIT` and checked by reading every interface they use, but not compiled: the repo needs Go 1.27.2 and its module mirror, which were unreachable where this was written. Step 1 compiles and tests it.

## Layouts

| Layout | Prefill | Decode | Why |
| --- | --- | --- | --- |
| **A** `layout-a-a30-prefill` | A30 | 2x Gaudi 3 | The plan's design. Relies on vLLM NIXL's smaller-to-larger block support (16 into 128); the Gaudi-side flags for this direction are not documented by vllm-gaudi. |
| **B** `layout-b-gaudi-prefill` | Gaudi 3 | A30 | The direction vllm-gaudi documents (`VLLM_HPU_NIXL_JOINT_KV`). Uses one Gaudi. Fallback if A fails the correctness gate. |
| **C** `layout-c-gaudi-flex` | A30, and each Gaudi for the other | 2x Gaudi 3 | Scenario 3 from the plan. Experimental. |

The router config is the same for every layout; only `profiles` change.

## Prerequisites

- OpenShift with the NVIDIA GPU Operator (A30 node) and the Intel Gaudi Base Operator (Gaudi node), in one cluster.
- `oc`/`kubectl`, `helm` 3.14+, `podman`, `git`, Python 3.10+ with `pip install -r scripts/requirements.txt`.
- A registry you can push to (examples use `quay.io/<you>`).
- A Hugging Face token with access to `meta-llama/Llama-3.1-8B-Instruct`.

```bash
cd lab   # from the repository root
export NS=hetero-pd-lab REG=quay.io/<you> KIT=$PWD
oc new-project $NS
oc create secret generic llm-d-hf-token --from-literal=HF_TOKEN=$HF_TOKEN -n $NS
```

## Step 1: Build and test the EPP with the plugin

```bash
git clone https://github.com/llm-d/llm-d-inference-scheduler.git && cd llm-d-inference-scheduler
git checkout -b hetero-pd-decider $(cat $KIT/../plugin/llm-d-patch/BASE_COMMIT)
git apply $KIT/../plugin/llm-d-patch/hetero-pd-decider.patch

# Unit tests run in the repo's builder container (no host Go needed).
make test-filter PATTERN='HeteroPD|TestDecide|TestConfigValidate' TYPE=epp
make test-filter PATTERN='Disagg|PrefixBased' TYPE=epp        # existing deciders still pass
make lint                                                       # repo lint rules

make image-build-epp EPP_IMAGE=$REG/llm-d-router-endpoint-picker:hetero-pd-dev
make image-push-epp  EPP_IMAGE=$REG/llm-d-router-endpoint-picker:hetero-pd-dev
```

If a test or the build fails, the error will name a file and line in `hetero_pd_decider.go` or its test; send it over and I'll fix it. Then set `router.epp.image.registry` in `router/common.values.yaml` to `$REG`.

## Step 2: Build the Gaudi vLLM image

Pin vLLM v0.26.0 on both vendors; NIXL handshakes check versions.

```bash
git clone https://github.com/vllm-project/vllm-gaudi.git && cd vllm-gaudi
podman build -f .cd/Dockerfile.ubuntu.pytorch.vllm.nixl.latest \
  --build-arg VLLM_GAUDI_COMMIT=v0.26.0 --build-arg VLLM_PROJECT_COMMIT=v0.26.0 \
  -t $REG/vllm-gaudi-nixl:v0.26.0 .
podman push $REG/vllm-gaudi-nixl:v0.26.0
```

Set `newName` in `modelserver/layout-*/kustomization.yaml` to `$REG/vllm-gaudi-nixl`. The A30 uses `docker.io/vllm/vllm-openai:v0.26.0`.

## Step 3: Deploy the model servers

```bash
oc get nodes -L nvidia.com/gpu.product      # confirm the A30 label value used in nodeSelector
oc apply -n $NS -k $KIT/modelserver/layout-a-a30-prefill
oc get pods -n $NS -w                         # Gaudi warmup can take 15+ minutes
```

Check each engine answers directly:

```bash
oc port-forward -n $NS deploy/prefill-a30 18000:8000 &
oc port-forward -n $NS deploy/decode-gaudi3 18200:8200 &
curl -s localhost:18000/v1/models; curl -s localhost:18200/v1/models
```

## Step 4: Correctness gate (does cross-vendor KV transfer work?)

Install the router with every request forced through remote prefill, then compare against Gaudi-only output.

```bash
helm install hetero-pd oci://ghcr.io/llm-d/charts/llm-d-router-standalone \
  -f $KIT/router/common.values.yaml -f $KIT/router/always.values.yaml -n $NS
oc port-forward -n $NS svc/hetero-pd-epp 8081:80 &
cd $KIT/scripts
python correctness.py --router http://localhost:8081 --reference http://localhost:18200 \
  --model meta-llama/Llama-3.1-8B-Instruct --prompts 200
```

Pass: identical 64-token output on at least 95% of prompts. Also check the decode pod logs show the KV was received, not recomputed (`oc logs deploy/decode-gaudi3 -c modelserver | grep -i nixl`), and the decode's `vllm:external_prefix_cache_hits_total` metric rises during the run.

If it fails, see Troubleshooting. If layout A cannot pass, switch to layout B (`oc delete -k ...layout-a...; oc apply -k ...layout-b...`) and repeat this step. The plugin and steps 5 to 7 are unchanged.

## Step 5: Measure the profile and the link

Run with no other traffic.

```bash
python profile_prefill.py --model meta-llama/Llama-3.1-8B-Instruct \
  --target nvidia-a30=http://localhost:18000 --target intel-gaudi3=http://localhost:18200
./measure_link.sh <a30-node> <gaudi-node> $NS
```

Copy the printed `profiles` block and `bandwidthGbps` into `router/hetero.values.yaml`.

## Step 6: A/B test against the stock decider

Same workload and seed under each config. Each run takes about 6 minutes including drain.

```bash
helm upgrade hetero-pd oci://ghcr.io/llm-d/charts/llm-d-router-standalone \
  -f $KIT/router/common.values.yaml -f $KIT/router/stock.values.yaml -n $NS
python loadtest.py --url http://localhost:8081 --model meta-llama/Llama-3.1-8B-Instruct --out run-stock.csv

helm upgrade hetero-pd oci://ghcr.io/llm-d/charts/llm-d-router-standalone \
  -f $KIT/router/common.values.yaml -f $KIT/router/hetero.values.yaml -n $NS
python loadtest.py --url http://localhost:8081 --model meta-llama/Llama-3.1-8B-Instruct --out run-hetero.csv

python compare.py stock=run-stock.csv hetero=run-hetero.csv
./decisions.sh hetero-pd $NS
```

The port-forward drops when the EPP pod restarts after `helm upgrade`; restart it before each run. Repeat each config at least 3 times and compare medians; single runs on a small lab are noisy.

Workload (defaults): 32 chat users looping 200-word prompts with 256-token outputs, long 2,000-word prompts arriving at 0.5/s with 64-token outputs, and a burst of 10 long prompts at 150 s. Raise `--chat-users` until the Gaudi pods show 30+ running requests (`vllm:num_requests_running`), so the stall term matters.

What to look for:

| Metric in compare.py | Expected with hetero-pd-decider | Why |
| --- | --- | --- |
| `chat` ITL p95 | Lower or equal | Long prompts offloaded from busy Gaudi pods do not stall chat streams |
| `burst` TTFT p95 | Lower | Overflow beyond the SLO prefills locally instead of queueing on the A30 |
| `long` TTFT p50 | Lower when Gaudi is lightly loaded | Idle Gaudi prefills locally, skipping the A30 and the transfer |
| `all` out tok/s | Equal or higher | Less interference on decode |

If hetero does not beat stock on any row, say so in the results; that is a valid finding for the proposal.

## Step 7: Check each decision path

`decisions.sh` shows counts by reason. Force each one:

| Reason | How to trigger |
| --- | --- |
| `remote-better` | Load test running (busy Gaudi), long prompts |
| `local-better` | No load; send single long prompts |
| `remote-misses-slo` | Burst phase, or set `ttftSLOMs: 300` |
| `short-prompt` | Chat traffic (200-word prompts) |
| `no-prefill-candidate` | `oc label pod -l app=prefill-a30 llm-d.ai/hetero-pd-disabled=true --overwrite`, or a different `llm-d.ai/model-fingerprint` on the A30 |
| `decode-kv-full` | Set `maxDecodeKVUsage: 0.2` under load |
| `missing-profile` | Remove `intel-gaudi3` from `profiles`; requests then use `fallbackNonCachedTokens` |

The EPP log line `hetero-pd-decider decision` carries `remoteSeconds`, `localSeconds`, `stallSeconds` and `transferSeconds` per request. Compare `remoteSeconds` with measured TTFT from the load test to check the model's accuracy.

## Step 8 (optional): Layout C

```bash
oc delete -n $NS -k $KIT/modelserver/layout-a-a30-prefill
oc apply  -n $NS -k $KIT/modelserver/layout-c-gaudi-flex
```

Add `sameClassBandwidthGbps` (Gaudi-to-Gaudi link speed from `measure_link.sh` between the two Gaudi pods' nodes, or same-node) to `hetero.values.yaml`, rerun step 6, and check that some `remote-better` decisions name a Gaudi pod in the log's `prefillPod` field.

## Troubleshooting

| Symptom | Likely cause and fix |
| --- | --- |
| EPP CrashLoop: `plugin type hetero-pd-decider not found` | The EPP image is the stock one. Check `router.epp.image` and `pullPolicy: Always`. |
| EPP startup error about data keys or producers | Keep `approx-prefix-cache-producer` in the plugin list; the decider requires its match info. |
| `decisions.sh` shows only `no-prefill-candidate` and the EPP log says "has no prefill pod view" | `Produce` is not running. Confirm `hetero-pd-decider` is listed under `plugins`, not only referenced by the handler. |
| Prefill pods not found by the router | Pods need `llm-d.ai/guide: hetero-pd` (the InferencePool selector) and `llm-d.ai/role`. |
| Correctness fails with early divergence (first few tokens) | KV layout or block mismatch. On layout A try adding `"enable_permute_local_kv":true` to the A30 kv-transfer-config; check both engines log the same vLLM version; then try layout B. |
| Decode logs show the prompt recomputed, no NIXL transfer | Side-channel port 5600 blocked between nodes (NetworkPolicy), or `VLLM_NIXL_SIDE_CHANNEL_HOST` not the pod IP. |
| NIXL handshake errors mentioning compatibility | Mismatched vLLM versions between the two images. |
| Very high TTFT on remote path | TCP link speed. Run `measure_link.sh`; the decider will route around it once `bandwidthGbps` is set. |

## Results to bring back

`run-*.csv` for each config and repeat, `compare.py` output, `decisions.sh` output, the measured profiles and link speed, and the correctness result. These fill the cost section of the plan and the proposal's validation plan.
