#!/usr/bin/env python3
"""PHASE 3 (live, transformers edition), run on the A30: prefill prompts and
stream their KV to the Gaudi decode server.

    python scripts/phase3_prefill_client.py --model /models/Llama-3.1-8B-Instruct \
        --connect tcp://<gaudi-node>:5557 --device cuda --prompt "Explain RDMA"

Prints per-request transfer size, time and measured Gbit/s. That measured
bandwidth is the T_transfer input for the Kubernetes scorer.
"""

import argparse
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import torch  # noqa: E402

from xvkv.adapters import HFCacheAdapter, resolve_device  # noqa: E402
from xvkv.hf_runner import encode_chat, export_prefill  # noqa: E402
from xvkv.identity import identity_from_model_dir  # noqa: E402
from xvkv.transport import KVSender  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", required=True)
    ap.add_argument("--connect", required=True)
    ap.add_argument("--device", default="cuda")
    ap.add_argument("--prompt", action="append", required=True)
    args = ap.parse_args()

    from transformers import AutoModelForCausalLM, AutoTokenizer

    device = resolve_device(args.device)
    tok = AutoTokenizer.from_pretrained(args.model)
    model = AutoModelForCausalLM.from_pretrained(args.model, dtype=torch.bfloat16).to(device).eval()
    adapter = HFCacheAdapter(identity_from_model_dir(args.model), "nvidia", "transformers")
    tx = KVSender(args.connect)

    for i, text in enumerate(args.prompt):
        ids = encode_chat(tok, text)
        t0 = time.perf_counter()
        header, frames = export_prefill(model, adapter, ids, device, f"req-{i}")
        t1 = time.perf_counter()
        # transformers finishes every layer before returning, so layers are
        # sent after prefill here; the vLLM connector streams them per layer.
        tx.begin(header)
        for f in frames:
            tx.send_layer(f)
        tx.finish()
        t2 = time.perf_counter()
        mib = tx.stats.bytes_sent / 2**20 if tx.stats.requests == 1 else None
        print(f"req-{i}: {len(ids)} tokens  prefill {t1 - t0:.3f}s  "
              f"transfer {t2 - t1:.3f}s  {tx.stats.last_gbps:.2f} Gbit/s"
              + (f"  {mib:.1f} MiB" if mib else ""))
    tx.close()


if __name__ == "__main__":
    main()
