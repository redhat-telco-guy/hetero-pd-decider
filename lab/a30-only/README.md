# A30-only hetero-PD lab: scripted build

Rebuilds the lab that ran on `ai154` (October 2026) on any OpenShift cluster with two NVIDIA A30s:
one A30 reads prompts (prefill), the other writes answers (decode), and the llm-d router with
hetero-pd-decider decides per request whether to hand the prompt over.

```
oc login --token=... --server=https://api.<cluster>:6443
cd ~/hetero-pd-decider
vi lab/a30-only/config.env          # namespace, model, A30 label (defaults match the first lab)
bash lab/a30-only/install-all.sh 2>&1 | tee a30-install.txt
```

About 45–75 minutes the first time: the NVIDIA driver build and the model download take most of it.
Each step can also be run on its own, and re-running a finished step is safe.

## Steps

| Step | Script | What it does | Time |
|---|---|---|---|
| 0 | `00-preflight.sh` | Checks `oc`, `helm`, `git`, `python3`, the login, nodes and the internal image registry | 1 min |
| 1 | `01-operators.sh` | Installs Node Feature Discovery and the NVIDIA GPU Operator from the cluster catalog | 5 min |
| 2 | `02-gpus.sh` | Creates NFD and the NVIDIA ClusterPolicy, turns MIG off, waits for 2 whole A30s | 10–25 min |
| 3 | `03-namespace.sh` | Namespace, Hugging Face token secret, service account with `anyuid` | 1 min |
| 4 | `04-router-image.sh` | Builds the llm-d router with the plugin in-cluster (clone, patch, vet, test, compile) | 10–15 min |
| 5 | `05-model-servers.sh` | vLLM 0.26.0 + Qwen2.5-7B-Instruct on both A30s, NIXL KV transfer, routing sidecar | 10–20 min |
| 6 | `06-router.sh` | Helm install of the router with all decision configs; your plugin (auto) is the default | 3 min |
| 7 | `07-dashboard.sh` | The lab dashboard (decision walkthrough, router mode, traffic, test suites, value) | 2 min |
| 8 | `08-check.sh` | Correctness gate: answers with and without the handoff compared | 5 min |

## Versions pinned

| Component | Version |
|---|---|
| llm-d (router, chart, plugin base) | commit in `plugin/llm-d-patch/BASE_COMMIT` |
| Routing sidecar | `ghcr.io/llm-d/llm-d-router-disagg-sidecar:v1.0.0` (`--kv-connector=nixlv2`) |
| vLLM | `docker.io/vllm/vllm-openai:v0.26.0` |
| Model | `Qwen/Qwen2.5-7B-Instruct`, bf16, max length 8192, block size 16 |
| KV transfer | NixlConnector, `kv_role=kv_both`, `kv_buffer_device=cpu`, UCX over TCP |
| Go (router build) | `golang:1.27.2` |

## Workarounds built into the scripts

Every one of these stopped the first build at some point. They are now handled automatically.

| Problem on the first lab | Fix | Where |
|---|---|---|
| A30 reported `MIG-INVALID`, no schedulable GPUs | Label each NVIDIA node `nvidia.com/mig.config=all-disabled`; restart the device plugin if it keeps the old view | `02-gpus.sh` |
| KMM operator copies its CSV into every namespace, so the wrong one was picked | Select each operator's CSV by name prefix | `02-gpus.sh` |
| vLLM image writes under `/root`, blocked by the restricted SCC | Service account `hetero-pd` with `anyuid` | `03-namespace.sh` |
| OpenShift binary builds ignore `--build-arg` | `BASE_COMMIT` written into the uploaded Dockerfile | `04-router-image.sh` |
| Go build failed with `fatal error: newosproc` | `GOMAXPROCS=4`, `GOFLAGS=-p=4` in the Dockerfile; build pinned to an A30 node with 8 CPU / 16 GiB | `lab/build/epp/Dockerfile`, `04-router-image.sh` |
| Router refused to load the plugin (Alpha) | EPP flag `--allow-experimental-plugins=true` | `lab/router/common.values.yaml` |
| No InferencePool CRD on the cluster | `inferencePool.create: false`; router selects pods by label | `lab/router/common.values.yaml` |
| Envoy crash-looped on the broken Gaudi node | Router pinned to an A30 node | `06-router.sh` |
| `helm upgrade` conflict after a dashboard mode switch | `--force-conflicts`, then restart so the newly built image is pulled | `06-router.sh` |
| Meta Llama 3.1 8B is gated (403) | Qwen2.5-7B-Instruct (ungated); change `MODEL` in `config.env` if you have access | `config.env` |
| Rolling update deadlocked on a single GPU | `strategy: Recreate` on the GPU deployments | model server YAMLs |
| Special characters garbled on the dashboard | UTF-8 `meta charset` and server headers | `lab/dashboard2` |

## Bring back the first lab's results

```
bash lab/scripts/35-restore-history.sh lab-archive/2026-10-29/results/history.json --merge
```

Old runs appear next to new ones on the dashboard, tagged with the lab they came from.

## Adding Gaudi later

The Gaudi path (Intel Gaudi Base Operator, KMM, the `vllm-gaudi` image with the pinned
`transformers 5.14.1`, memory settings for `decode-gaudi3`) is in `lab/scripts/01–15` and
`lab/modelserver/layout-a-a30-prefill` / `layout-b-gaudi-prefill`. It is not part of this A30-only path.
