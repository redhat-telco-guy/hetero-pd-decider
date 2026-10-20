#!/usr/bin/env python3
"""PHASE 2, run on the A30 node: prefill each prompt and export its KV cache.

    python scripts/phase2_export.py --model /models/Llama-3.1-8B-Instruct \
        --prompts prompts.jsonl --out handoffs/ --device cuda

prompts.jsonl: one {"id": "...", "text": "..."} per line.
Writes handoffs/<id>.xvkv (wire format) for phase2_decode.py on Gaudi.
"""

import argparse
import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import torch  # noqa: E402

from xvkv.adapters import HFCacheAdapter, resolve_device  # noqa: E402
from xvkv.hf_runner import encode_chat, export_prefill  # noqa: E402
from xvkv.identity import identity_from_model_dir, kv_bytes_per_token  # noqa: E402
from xvkv.wire import write_handoff  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", required=True)
    ap.add_argument("--prompts", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--device", default="cuda")
    ap.add_argument("--vendor", default="nvidia")
    ap.add_argument("--chat", action="store_true", help="apply the chat template")
    args = ap.parse_args()

    from transformers import AutoModelForCausalLM, AutoTokenizer

    device = resolve_device(args.device)
    tok = AutoTokenizer.from_pretrained(args.model)
    model = AutoModelForCausalLM.from_pretrained(args.model, dtype=torch.bfloat16).to(device).eval()
    identity = identity_from_model_dir(args.model)
    adapter = HFCacheAdapter(identity, args.vendor, f"transformers-{__import__('transformers').__version__}")
    print(f"identity: {identity}\nKV per token: {kv_bytes_per_token(identity) / 1024:.1f} KiB")

    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    rows = [json.loads(l) for l in Path(args.prompts).read_text().splitlines() if l.strip()]
    for row in rows:
        if args.chat:
            ids = encode_chat(tok, row["text"])
        else:
            ids = tok(row["text"])["input_ids"]
        t0 = time.perf_counter()
        header, frames = export_prefill(model, adapter, ids, device, row["id"])
        t1 = time.perf_counter()
        n = write_handoff(out / f"{row['id']}.xvkv", header, frames)
        print(f"{row['id']}: {len(ids)} tokens, prefill+export {t1 - t0:.3f}s, "
              f"{n / 2**20:.1f} MiB, first token {header.first_output_token}")
    (out / "prompts.jsonl").write_text(Path(args.prompts).read_text())


if __name__ == "__main__":
    main()
