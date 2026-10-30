**Title:** Feature: hardware-aware P/D decider for mixed accelerator pools (`hetero-pd-decider`)

**Repo:** llm-d/llm-d-router · template: Feature request

---

**What would you like to be added**:

A P/D decider plugin for `disagg-profile-handler` that decides per request whether remote prefill is worth the KV handoff. It weighs the speed of each accelerator class, current load, and the cost of the KV transfer, not only the uncached prompt length. It is meant for pools that mix accelerator types or vendors, for example NVIDIA A30 + Intel Gaudi 3. In homogeneous pools it behaves like stock.

I have a working implementation, built and tested against this repo:
- Code and patch: https://github.com/redhat-telco-guy/hetero-pd-decider (`plugin/llm-d-patch/hetero-pd-decider.patch`)
- The patch applies cleanly to `v1.0.0` and to `main` (checked against e0b94fb, Oct 30). It is registered as Alpha and enabled with `--allow-experimental-plugins`.

**Why is this needed**:

Today the only conditional P/D logic is a fixed threshold on the uncached prompt suffix:

> `prefix-based-pd-decider`: "Disaggregate prefill when `(inputTokens - hitPrefixTokens) >= nonCachedTokens`. `nonCachedTokens = 0` disables it." ([docs/coordinator_architecture.md](https://github.com/llm-d/llm-d-router/blob/main/docs/coordinator_architecture.md))

The current docs leave hardware out of that decision:
- The default `nonCachedTokens` is 0 (never split), and the doc examples use 8 ([docs/disaggregation.md](https://github.com/llm-d/llm-d-router/blob/main/docs/disaggregation.md)). The well-lit P/D guide uses `always-disagg-pd-decider` ([P/D guide](https://llm-d.ai/docs/well-lit-paths/foundations/pd-disaggregation)).
- The predicted-latency path should be skipped for mixed pools, because its feature vector "captures pod load state without encoding hardware shape, so it assumes a homogeneous pool" ([predicted-latency guide](https://llm-d.ai/docs/well-lit-paths/foundations/predicted-latency)).
- KV transfer cost is not a decision input, although the architecture doc notes that NIXL over TCP is "extremely slow" ([architecture](https://llm-d.ai/docs/architecture/disaggregation/pd-disaggregation)).

So with a fast card and a slow card from different vendors, one fixed number decides every request, whatever the cards' speeds, queues, or link. A long prompt can be moved to a slower or busy prefill card, or over a slow link, and arrive later than if it had stayed local. The reverse also happens: a large prompt that a much faster card would finish sooner is kept local.

**Proposed behaviour (as implemented)**

`strategy: auto` (default) works in four steps:
1. **Stock answer first.** Run the same rule as `prefix-based-pd-decider` (`stockNonCachedTokens`, default 1024).
2. **Safety checks.** Keep the request local if the decode pod is disabled, KV usage is ≥ 0.9, there is no eligible prefill pod, or the prompt is under 256 tokens. Fall back to stock if any class lacks a profile.
3. **Price both paths:**
   - keep = U/R_D + w·f·N_D·U/R_D (local prefill, plus the stall it causes for running decodes)
   - move = U/R_P + W_P·Q/R_P + U·b/BW + H (remote prefill, plus prefill queue, KV transfer, and fixed handoff)
4. **Overrule stock only when clearly better.** The other path must be ≥ 25% cheaper (`overrideMargin`). A move must also fit the TTFT SLO.

Here U is uncached tokens, R is prefill tokens/s per accelerator class (from the pod label `llm-d.ai/accelerator-class`), Q is queued prefill tokens, b is KV bytes per token, and BW is link bandwidth. Each decision is exported as `llm_d_epp_hetero_pd_decision_total{reason}`, where `reason` is one of `stock-split`, `stock-keep`, `override-keep`, `override-move`, `short-prompt`, `decode-kv-full`, `decode-disabled`, or `no-prefill-candidate`.

**Results so far** (OpenShift 4.22, 2 × NVIDIA A30, Qwen2.5-7B-Instruct, vLLM 0.26.0, NIXL over TCP, 3 suites × 6 scenarios, 9 repeats vs stock at `nonCachedTokens: 1024`):
- Idle, long documents: time to first token fell **0.71 s → 0.35 s (−50%)**. The plugin keeps work local where a handoff did not pay.
- The other 5 scenarios were a **tie**: same decisions, results within noise. In particular, it did not regress where stock was already right.
- NIXL handoff measured 2–5 ms when idle. Under load, 71% of 27,769 transfers took 0.1–0.75 s over TCP. That is why transfer cost belongs in the decision.
- Mixed-vendor (A30 + Gaudi 3): the plugin deploys and makes cross-vendor decisions (smoke test). Full suites are pending a hardware cooling fix on our Gaudi server.

**Open questions for maintainers**
1. Should this be a separate plugin, or an optional cost-aware mode of `prefix-based-pd-decider`?
2. Accelerator class comes from a pod label, and prefill rates are configured per class. Is there a preferred source, such as the data layer, or the throughput calibration used by `prefix-cache-affinity-filter` (`peakPrefillThroughput`)?
3. The plugin does not yet implement the conditional-decode `Prefer: if-available` 412 gate. Should a hardware-aware decider also own that gate?

Happy to open a PR, add docs and a well-lit-path variant, and run more scenarios (including mixed-vendor) on request.

/cc happy to take this: `/assign`
