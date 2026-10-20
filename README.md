# hetero-pd-decider

Per-request prefill/decode disaggregation decisions for [llm-d](https://llm-d.ai) when prefill and decode pods run on different accelerators, including different vendors.

llm-d and vLLM can already move a KV cache between vendors (vLLM NixlConnector, the Intel Gaudi plugin's heterogeneous NIXL path). What llm-d lacks is a decision that accounts for the hardware: its `prefix-based-pd-decider` splits a request whenever the uncached prompt exceeds one fixed threshold. `hetero-pd-decider` replaces that threshold with an estimate per request.

## How it decides

After llm-d picks the decode pod, the decider compares:

```
remote = U / R_prefill + queue_prefill + U * kvBytesPerToken / bandwidth
local  = U / R_decode  + queue_decode
stall  = running_streams_on_decode * U / R_decode

split when remote <= TTFT SLO  and  remote < (1 - margin) * (local + stallWeight * stall)
```

- `U` is the prompt's uncached tokens on the chosen decode pod.
- `R` is measured prefill throughput for the pod's accelerator class (the `llm-d.ai/accelerator-class` label).
- `stall` is the delay local prefill imposes on every stream already generating on the decode pod.

Requests stay local when the prompt is short, the decode KV cache is nearly full, pods serve different model builds, a pod is opted out by label, or no prefill pod would meet the SLO. Without a profile for the decode pod's class, the plugin falls back to the stock fixed-threshold behavior.

| Situation (A30 prefill, Gaudi 3 decode, illustrative numbers) | Stock decider | hetero-pd-decider |
| --- | --- | --- |
| Long prompt, decode pod busy | Remote | Remote, no stall for active users |
| Long prompt, decode pod idle | Remote, ~0.5 s TTFT | Local, ~0.1 s TTFT |
| Burst of long prompts | All queue on the A30 | Remote up to the SLO, overflow local |
| Short or cached prompt | Local | Local |
| Slow link, full KV, model mismatch | Remote if long | Local |

See [docs/design.md](docs/design.md) for the full model and all scenarios.

## Repository layout

| Path | Contents |
| --- | --- |
| [`plugin/llm-d-patch/`](plugin/llm-d-patch) | Patch for [llm-d-inference-scheduler](https://github.com/llm-d/llm-d-inference-scheduler) at the commit in `BASE_COMMIT` |
| [`plugin/src/`](plugin/src) | Readable copies of the plugin sources from the patch, plus a sample EPP config |
| [`plugin/src/hetero/`](plugin/src/hetero) | Decision core, standard library only, with its own `go.mod` for standalone tests |
| [`lab/`](lab) | Runbook, Helm values, Kustomize layouts and scripts for one NVIDIA A30 and two Intel Gaudi 3 on OpenShift |
| [`tools/xvkv/`](tools/xvkv) | Earlier cross-vendor KV handoff prototype; its drift harness checks cross-vendor output correctness |
| [`docs/`](docs) | Design notes |

## Quick start

Test the decision core (Go 1.22 or newer):

```bash
cd plugin/src/hetero && go test -v ./...
```

Build an llm-d EPP image with the plugin:

```bash
git clone https://github.com/llm-d/llm-d-inference-scheduler.git && cd llm-d-inference-scheduler
git checkout -b hetero-pd-decider $(cat ../plugin/llm-d-patch/BASE_COMMIT)
git apply ../plugin/llm-d-patch/hetero-pd-decider.patch
make test-filter PATTERN='HeteroPD|TestDecide|TestConfigValidate' TYPE=epp
make image-build-epp EPP_IMAGE=quay.io/<you>/llm-d-router-endpoint-picker:hetero-pd-dev
```

Configure it in the EPP plugin config:

```yaml
- type: disagg-profile-handler
  parameters:
    deciders:
      prefill: hetero-pd-decider
- type: hetero-pd-decider
  parameters:
    ttftSLOMs: 1000
    bandwidthGbps: 25
    profiles:
      nvidia-a30:   {prefillTokensPerSec: 5000}
      intel-gaudi3: {prefillTokensPerSec: 20000}
```

Then follow [lab/README.md](lab/README.md) to deploy, check correctness, profile the hardware and run the A/B test against the stock decider.

## Status

| Component | State |
| --- | --- |
| Decision core (`plugin/src/hetero`) | Compiled and tested; 98% statement coverage |
| llm-d adapter (`hetero_pd_decider.go`) and its tests | Written against llm-d-inference-scheduler at `BASE_COMMIT`; first compile happens in lab step 1 |
| Lab manifests and scripts | Kustomize layouts build; scripts tested against a mock OpenAI streaming server |
| Hardware results | Pending |

Plugin stability: Alpha.

## Related upstream work

- [vLLM NixlConnector roadmap](https://github.com/vllm-project/vllm/issues/33702) and [heterogeneous block size RFC](https://github.com/vllm-project/vllm/issues/26744)
- [vllm-gaudi heterogeneous NIXL connector](https://docs.vllm.ai/projects/gaudi/en/0.24.0/api/vllm_gaudi/distributed/kv_transfer/kv_connector/v1/hetero_hpu_nixl_connector.html)
- [llm-d disaggregated serving](https://llm-d.ai/docs/architecture/advanced/disaggregation) and [latency predictor](https://llm-d.ai/docs/dev/architecture/router/latency-predictor)
- [llm-d three-vendor heterogeneous serving](https://llm-d.ai/blog/heterogeneous-inference-3-vendor-sovereign-cluster)

## License

Apache License 2.0. The plugin is written as a contribution to llm-d, which is Apache 2.0.
