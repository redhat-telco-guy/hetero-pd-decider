# hetero-pd-decider

**A hardware-aware prefill/decode decider for [llm-d](https://llm-d.ai). For each request, it decides whether handing the prompt to another card, possibly from another vendor, is worth the KV transfer.**

In llm-d's prefill/decode (P/D) disaggregation, a request can be split: one card reads the prompt (prefill), then hands the KV cache over [NIXL](https://github.com/ai-dynamo/nixl) to the card that writes the answer (decode). The alternative is that the decode card does both. `hetero-pd-decider` makes that choice per request, using how fast each card is, how busy it is, and what the handoff costs. It starts from llm-d's own answer and changes it only when the other path is clearly faster.

## The gap in llm-d today

The only conditional rule in llm-d is a fixed threshold on the part of the prompt the decode card has not cached:

> "Disaggregate prefill when `(inputTokens - hitPrefixTokens) >= nonCachedTokens`. `nonCachedTokens = 0` disables it." ([llm-d-router docs](https://github.com/llm-d/llm-d-router/blob/main/docs/coordinator_architecture.md))

| What llm-d does today | Source |
| --- | --- |
| Default `nonCachedTokens: 0`, which means never split. The doc examples use 8, which splits almost every request. | [docs/disaggregation.md](https://github.com/llm-d/llm-d-router/blob/main/docs/disaggregation.md) |
| The official P/D guide uses `always-disagg-pd-decider`: every request is split. | [P/D guide](https://llm-d.ai/docs/well-lit-paths/foundations/pd-disaggregation) |
| The predicted-latency router should be skipped for mixed pools: it "assumes a homogeneous pool". | [Predicted latency](https://llm-d.ai/docs/well-lit-paths/foundations/predicted-latency) |
| KV transfer cost is not a decision input, even though NIXL over TCP is called "extremely slow". | [P/D architecture](https://llm-d.ai/docs/architecture/disaggregation/pd-disaggregation) |

So one fixed number decides every request, whatever the cards, their queues, or the link between them. When an NVIDIA card and an Intel Gaudi share a pool, a long prompt can be sent to a slower or busier card, or over a slow link, and arrive later than if it had stayed put.

## How it decides (`strategy: auto`, the default)

| Step | What happens |
| --- | --- |
| 1. Stock answer first | Apply llm-d's rule: split if the uncached prompt is at least `stockNonCachedTokens` (1,024). |
| 2. Safety checks | Keep the request local if the prompt is short (< 256 tokens), there is no eligible prefill pod, the decode card's KV cache is ≥ 90% full, or decode is disabled. If any card class has no speed profile, use the stock answer. |
| 3. Price both paths | **keep** = local prefill time + the stall it causes for answers already streaming on that card.<br>**move** = remote prefill time + the remote card's queue + KV transfer time + fixed handoff time. |
| 4. Overrule only when clearly better | Change stock's answer only if the other path is at least 25% cheaper (`overrideMargin`), and for a move, only if it also meets the TTFT target. |

**Examples** (A30 reads prompts, Gaudi 3 writes answers, stock threshold 1,024 tokens):

| Situation | Stock | Plugin | Why |
| --- | --- | --- | --- |
| Long new document, Gaudi idle | split | **keep** | The Gaudi reads it faster itself, with no handoff. |
| Long new document, Gaudi busy with many streams | split | split | Moving protects the answers already streaming. |
| Long document, A30 queue backed up | split | **keep** | Waiting in the A30 queue costs more than it saves. |
| Chat turn, mostly cached | keep | keep | Little new text, so the handoff isn't worth it. |
| Short prompt | keep | keep | Below 256 tokens it always stays local. |
| Gaudi KV cache 95% full | split | **keep** | Safety: the KV lands on the Gaudi either way, so a transfer adds cost and risk without freeing memory. |

Each decision is counted in `llm_d_epp_hetero_pd_decision_total{reason}`, where `reason` is `stock-split`, `stock-keep`, `override-keep`, `override-move`, `short-prompt`, `decode-kv-full`, `decode-disabled`, or `no-prefill-candidate`.

## Results so far

**Lab:** OpenShift 4.22, 2 × NVIDIA A30, Qwen2.5-7B-Instruct, vLLM 0.26.0, NIXL over TCP. Compared against stock at `nonCachedTokens: 1024`, over 3 test suites × 6 scenarios (9 repeats).

| Scenario | Result |
| --- | --- |
| Idle, long documents | **First-token time 0.71 s → 0.35 s (−50%)** |
| The other 5 scenarios (busy chat, mixed traffic, bursts, cached chat, huge prompts) | **Tie**: same decisions and results within noise, so no regression where stock was already right |

NIXL handoff took 2–5 ms when idle. Under load, 71% of 27,769 transfers took 0.1–0.75 s over TCP. That's why transfer cost belongs in the decision.

**Mixed vendor (A30 + Intel Gaudi 3):** the plugin builds, deploys and makes cross-vendor decisions (smoke test: `override-keep` with the Gaudi as the decode card). Full test suites are waiting on a cooling fix for the Gaudi server.

## Quick start

Test the decision core (Go 1.22+):

```bash
cd plugin/src/hetero && go test -v ./...
```

Build an llm-d router image with the plugin. The patch applies to the commit in `BASE_COMMIT`, to `v1.0.0`, and to current `main`.

```bash
git clone https://github.com/llm-d/llm-d-router.git && cd llm-d-router
git checkout -b hetero-pd-decider $(cat ../plugin/llm-d-patch/BASE_COMMIT)
git apply ../plugin/llm-d-patch/hetero-pd-decider.patch
make image-build-epp EPP_IMAGE=quay.io/<you>/llm-d-router-endpoint-picker:hetero-pd-dev
```

Configure it (Alpha plugin, so start the router with `--allow-experimental-plugins=true`). Pods need the labels `llm-d.ai/role` and `llm-d.ai/accelerator-class`.

```yaml
- type: disagg-profile-handler
  parameters:
    deciders:
      prefill: hetero-pd-decider
- type: hetero-pd-decider
  parameters:
    strategy: auto              # auto | model | guarded-stock
    stockNonCachedTokens: 1024  # stock's threshold, used as the starting answer
    overrideMargin: 0.25        # overrule stock only when the other path is 25% cheaper
    ttftSLOMs: 1000
    bandwidthGbps: 10
    handoffOverheadMs: 82       # measure on your cluster
    kvBytesPerToken: 57344      # Qwen2.5-7B, bf16
    profiles:
      nvidia-a30:   {prefillTokensPerSec: 7035}   # measured
      intel-gaudi3: {prefillTokensPerSec: 20000}  # placeholder until measured
```

The full sample is in [plugin/src/hetero-pd-epp-config.yaml](plugin/src/hetero-pd-epp-config.yaml).

## Repository layout

| Path | Contents |
| --- | --- |
| [`plugin/llm-d-patch/`](plugin/llm-d-patch) | The patch for llm-d-router, and the commit it was built on |
| [`plugin/src/`](plugin/src) | Readable plugin sources, tests (100% coverage of the decision core) and a sample config |
| [`lab/a30-only/`](lab/a30-only) | Scripted rebuild of the A30 lab on any OpenShift cluster with two A30s |
| [`lab/mixed/`](lab/mixed) | A30 + Gaudi 3 build and deploy, the in-cluster Gaudi thermal watchdog, and the thermal test |
| [`lab/dashboard2/`](lab/dashboard2) | Lab dashboard: decision walkthrough, router mode switch, traffic and test suites, value summary |
| [`lab/hwmon/`](lab/hwmon) | Live hardware panel (fans, temperatures, power and network cards from the BMC and drivers) and a heat test |
| [`lab/scripts/`](lab/scripts) | Step-by-step lab scripts: operators, builds, calibration, correctness, health checks, export |
| [`lab-archive/*/results/`](lab-archive) | Raw suite results and run history behind the numbers above |
| [`docs/`](docs) | Design notes and the upstream feature request |
| [`tools/xvkv/`](tools/xvkv) | Earlier cross-vendor KV handoff prototype and its output-drift checks |

## Roadmap

- **Measure card speeds automatically** instead of configuring them, so a new accelerator class works without hand-entered figures.
- **Mixed-vendor test suites** (A30 + Gaudi 3, both directions) once the Gaudi server's cooling is fixed.
- **Choose between specific prefill pods**, for example an idle Gaudi preparing a prompt for a busy one, instead of only "remote pool or local".
- **Cost mode:** when several paths meet the target, prefer the cheaper hardware.

See [docs/design.md](docs/design.md) for the original design and the longer list of scenarios.

## Related work

- [llm-d P/D disaggregation](https://llm-d.ai/docs/architecture/disaggregation/pd-disaggregation) and [predicted-latency routing](https://llm-d.ai/docs/well-lit-paths/foundations/predicted-latency)
- [vllm-gaudi heterogeneous NIXL connector](https://docs.vllm.ai/projects/gaudi/en/0.24.0/api/vllm_gaudi/distributed/kv_transfer/kv_connector/v1/hetero_hpu_nixl_connector.html)
- [llm-d three-vendor heterogeneous serving](https://llm-d.ai/blog/heterogeneous-inference-3-vendor-sovereign-cluster)

## License

Apache License 2.0, the same as llm-d.
