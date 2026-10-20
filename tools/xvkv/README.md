# xvkv: cross-vendor KV cache handoff

Prefill on an NVIDIA A30, decode on Intel Gaudi 3. This package is the translation layer: every engine converts its KV cache to and from one neutral wire format, so the two vendors never need to know each other's memory layout.

```
A30 paged cache (16-tok blocks)                    Gaudi 3 paged cache (128-tok blocks)
        │ gather_layer (by block table)                   ▲ scatter_layer (into new blocks)
        ▼                                                 │
 canonical K,V [seq, kv_heads, head_dim] bf16 ──ZeroMQ──▶ validate header + CRC per layer
```

## Lab

| Node | Hardware | Role | Device flag |
|---|---|---|---|
| prefill | 1x NVIDIA A30 24 GB | prefill, producer | `--device cuda` |
| decode | 2x Intel Gaudi 3 128 GB | decode, consumer (one instance per card, TP=1) | `--device hpu` |

Model: Llama-3.1-8B-Instruct, BF16 weights and BF16 KV (the A30 has no FP8). Put identical model files on both nodes. Every handoff compares model, tokenizer and rope hashes and refuses on any mismatch.

## Layout

| Path | What it is |
|---|---|
| `xvkv/wire.py` | Header, layer frames, CRC32 per tensor, handoff files, consumer-side validation |
| `xvkv/identity.py` | Model, tokenizer and rope hashes; KV bytes per token |
| `xvkv/layout.py` | `LayoutSpec` and generic paged `gather_layer` / `scatter_layer`; `infer_spec` |
| `xvkv/adapters.py` | `PagedAdapter` (vLLM CUDA / vLLM Gaudi), `HFCacheAdapter` (transformers), HPU sync |
| `xvkv/transport.py` | ZeroMQ DEALER→ROUTER, layer-by-layer streaming, ACK/refusal, bandwidth stats |
| `xvkv/drift.py` | First-divergence, logit KL, pass/fail summary (the Dual-Key canary signal) |
| `xvkv/hf_runner.py` | Prefill / greedy decode helpers for the phase-2 proof |
| `xvkv/vllm_connector.py` | **Skeleton** vLLM v1 KV Connector (phase 3), wiring points marked TODO |
| `scripts/probe_kv_layout.py` | Prints the real vLLM cache layout on a node and the matching `LayoutSpec` |
| `scripts/phase2_export.py` | A30: prefill and write `.xvkv` handoff files |
| `scripts/phase2_decode.py` | Gaudi: decode from handoffs, plus a Gaudi-only reference run |
| `scripts/drift_report.py` | Pass/fail verdict: identical first 64 tokens on ≥95% of prompts |
| `scripts/phase3_*` | Live network handoff (transformers edition) |
| `tests/test_xvkv.py` | 26 CPU tests: re-blocking, tamper and mismatch refusal, ZeroMQ streaming, HF round trip |

## Install

```bash
pip install pyzmq transformers safetensors pytest
# A30 node: CUDA PyTorch.  Gaudi node: use Intel's Gaudi PyTorch container
# (it ships habana_frameworks); do NOT pip-install stock torch over it.
python -m pytest -q tests/        # runs on CPU, no GPU needed
```

## Phase 2: offline proof (start here)

This step uses transformers, not vLLM, so a result proves cross-vendor numerics without paging bugs in the way.

```bash
# A30 node
python scripts/phase2_export.py --model /models/Llama-3.1-8B-Instruct \
    --prompts prompts.jsonl --out handoffs/ --device cuda --chat
rsync -a handoffs/ gaudi-node:~/xvkv/handoffs/

# Gaudi 3 node
python scripts/phase2_decode.py --model /models/Llama-3.1-8B-Instruct \
    --handoffs handoffs/ --out results/ --device hpu --max-new-tokens 128
python scripts/drift_report.py results/        # exit code 0 = pass
```

`prompts.jsonl` holds one `{"id": "...", "text": "..."}` per line. Use around 200 prompts of mixed length (100 to 3,000 tokens).

What to expect: the A30 and Gaudi round BF16 differently, so the A30's first token can differ from Gaudi's own on close calls, and long greedy outputs eventually diverge. The pass bar is identical first 64 tokens on at least 95% of prompts. KL values from 1e-4 to 1e-3 are typical for BF16 noise. Values far above that point to a translation bug, most often rope.

## Phase 3: live handoff over the network

```bash
# Gaudi 3 node
python scripts/phase3_decode_server.py --model /models/Llama-3.1-8B-Instruct --bind tcp://0.0.0.0:5557 --device hpu
# A30 node
python scripts/phase3_prefill_client.py --model /models/Llama-3.1-8B-Instruct \
    --connect tcp://<gaudi-node>:5557 --device cuda --prompt "Explain RDMA in two sentences"
```

The client prints measured Gbit/s per handoff. Record it, because it is the `T_transfer` input for the Kubernetes scorer.

## Before writing the vLLM connector

1. Pin one vLLM version and the matching `vllm-gaudi` plugin release.
2. Run `scripts/probe_kv_layout.py` on both nodes and use the printed `LayoutSpec` in place of the defaults in `layout.py`. Those defaults are assumptions: the A30 uses 16-token blocks with K and V stacked; Gaudi uses 128-token blocks, flat slots, and K and V in separate tensors.
3. Open `vllm/distributed/kv_transfer/kv_connector/v1/base.py` for that version and align the signatures in `xvkv/vllm_connector.py`. Then resolve its TODOs. The two that matter most are getting the block IDs from the scheduler output, and sending `first_output_token` once sampling has produced it.

## Known limits

- Batch size 1 in the transformers adapter; the paged adapter is per request.
- One producer per consumer socket at a time; requests are serialized.
- Host-staged TCP only. An RDMA path (NIXL/UCX) is a later optimization.
- TP=1 on both sides. A different TP on each side needs KV-head resharding in the adapter.
