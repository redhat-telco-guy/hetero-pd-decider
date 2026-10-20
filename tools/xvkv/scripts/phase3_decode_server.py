#!/usr/bin/env python3
"""PHASE 3 (live, transformers edition), run on Gaudi 3: receive KV over the
network, decode, print results.

    python scripts/phase3_decode_server.py --model /models/Llama-3.1-8B-Instruct \
        --bind tcp://0.0.0.0:5557 --device hpu

Pairs with phase3_prefill_client.py on the A30. This exercises the real
network path and handoff validation before the vLLM connector is wired in.
"""

import argparse
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import torch  # noqa: E402

from xvkv.adapters import HFCacheAdapter, resolve_device  # noqa: E402
from xvkv.hf_runner import greedy_decode  # noqa: E402
from xvkv.identity import identity_from_model_dir  # noqa: E402
from xvkv.transport import KVReceiver  # noqa: E402
from xvkv.wire import HandoffError  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", required=True)
    ap.add_argument("--bind", default="tcp://0.0.0.0:5557")
    ap.add_argument("--device", default="hpu")
    ap.add_argument("--max-new-tokens", type=int, default=128)
    args = ap.parse_args()

    from transformers import AutoModelForCausalLM, AutoTokenizer

    device = resolve_device(args.device)
    tok = AutoTokenizer.from_pretrained(args.model)
    model = AutoModelForCausalLM.from_pretrained(args.model, dtype=torch.bfloat16).to(device).eval()
    adapter = HFCacheAdapter(identity_from_model_dir(args.model), "intel", "transformers")
    rx = KVReceiver(args.bind, recv_timeout_ms=24 * 3600 * 1000)
    print(f"listening on {args.bind}")

    while True:
        header = rx.next_header()
        t0 = time.perf_counter()
        try:
            cache = adapter.import_(header, rx.frames(header), device, torch.bfloat16)
        except HandoffError as e:
            rx.drain(header)
            rx.ack(header, str(e))
            print(f"{header.request_id}: REFUSED — {e}")
            continue
        rx.ack(header)                       # producer may free its blocks now
        t1 = time.perf_counter()
        out = greedy_decode(model, cache, header.first_output_token,
                            args.max_new_tokens, device,
                            {tok.eos_token_id} if tok.eos_token_id is not None else None)
        t2 = time.perf_counter()
        print(f"\n{header.request_id}: {header.seq_len} prompt tokens from "
              f"{header.producer_vendor}; receive+import {t1 - t0:.3f}s, "
              f"decode {len(out.tokens)} tokens {t2 - t1:.3f}s")
        print(tok.decode(out.tokens, skip_special_tokens=True))


if __name__ == "__main__":
    main()
