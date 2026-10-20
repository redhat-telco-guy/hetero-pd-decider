# Design

## Problem

In P/D disaggregation, a prompt is prefilled on one pod and its KV cache is sent to a decode pod. On mixed hardware the right choice per request depends on things a fixed token threshold ignores: how fast each pool prefills, how busy each pool is, how fast the link is, and how many users are already streaming tokens on the decode pod.

## Inputs

| Input | Source in llm-d |
| --- | --- |
| Uncached tokens U | Tokenized prompt minus the prefix-cache match on the selected decode pod |
| Running streams N_D, waiting queue, KV usage | vLLM metrics scraped by the EPP |
| Accelerator class | Pod label, default `llm-d.ai/accelerator-class` |
| Prefill tokens/s per class | Plugin config `profiles`, measured with `lab/scripts/profile_prefill.py` |
| Link bandwidth | Plugin config, measured with `lab/scripts/measure_link.sh` |
| TTFT SLO, stall weight, margin | Plugin config |

The decider only receives the selected decode pod from llm-d, so the plugin also runs as a DataProducer: before scheduling it records every prefill-capable pod (`prefill`, `prefill-decode` and the encode variants) with its metrics.

## Decision

```
remote = U / R_P + Q_P + U * b / BW        (best compatible prefill pod)
local  = U / R_D + Q_D
stall  = N_D * U / R_D
Q      = waiting * avgQueuedPromptTokens / R

split when remote <= SLO and remote < (1 - m) * (local + w * stall)
```

`w` (`stallWeight`, default 0.25) sets how much one second of stall summed over active streams counts against one second of the new request's wait. With placeholder lab numbers (A30 5,000 tok/s, Gaudi 3 20,000 tok/s, 25 GbE, 2,000-token prompts) a Gaudi decode pod starts offloading at about 18 running streams.

## Gates and fallbacks

| Condition | Result | Metric reason |
| --- | --- | --- |
| U below `minUncachedTokens` | Local | `short-prompt` |
| Decode pod has the disable label | Local | `decode-disabled` |
| Decode KV usage at or above `maxDecodeKVUsage` | Local | `decode-kv-full` |
| No compatible, profiled prefill pod | Local | `no-prefill-candidate` |
| Best remote estimate above the SLO | Local | `remote-misses-slo` |
| Decode class has no profile | `fallbackNonCachedTokens` threshold | `missing-profile` |
| Remote cheaper | Remote | `remote-better` |
| Otherwise | Local | `local-better` |

Pods with different non-empty `llm-d.ai/model-fingerprint` labels never exchange KV.

## Scenarios

| # | Setup | Behavior |
| --- | --- | --- |
| 1 | Same hardware, fixed pools | Splits mainly to protect busy decode pods; little gain over the stock decider |
| 2 | Different vendors, fixed pools | Offloads from busy decode pods, prefills locally on idle ones, sheds bursts to local prefill |
| 3 | Decode pods also labeled `prefill-decode` | Chooses among the dedicated prefill pool and idle peers |
| 4 | Several prefill classes | Chooses the class with the earliest estimated first token |
| 5 | Pools resized by a controller | Same per-request choice; pool sizing is a separate component |
| 6 | Cost mode | Planned: prefer the cheaper path when both meet the SLO |
| 7 | Degraded link, full KV, mismatch | Keeps requests on one vendor |
| 8 | Missing profile or metrics | Behaves like the stock threshold |

## Limitations

- The estimate uses the best prefill pod; the prefill profile's scorers may pick another.
- Queue delay assumes a fixed prompt size per waiting request.
- Bandwidth is static configuration.
- llm-d's latency predictor is not yet used; adding accelerator class as a predictor feature would improve the estimates.

## Observability

- `llm_d_epp_hetero_pd_decision_total{plugin_name, reason, remote_prefill}`
- EPP log at verbosity 4: one `hetero-pd-decider decision` line per request with `remoteSeconds`, `localSeconds`, `stallSeconds`, `transferSeconds` and the prefill pod used.
