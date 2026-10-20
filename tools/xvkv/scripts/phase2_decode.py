#!/usr/bin/env python3
"""PHASE 2, run on a Gaudi 3 node: decode from A30 handoffs, plus a local reference.

    python scripts/phase2_decode.py --model /models/Llama-3.1-8B-Instruct \
        --handoffs handoffs/ --out results/ --device hpu --max-new-tokens 128

For every handoffs/<id>.xvkv it writes, under results/:
    cross.jsonl / reference.jsonl    tokens per request
    logits/<id>.cross.pt, .reference.pt   first decode-step logits
Then run scripts/drift_report.py results/.
"""

import argparse
import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import torch  # noqa: E402

from xvkv.adapters import HFCacheAdapter, resolve_device  # noqa: E402
from xvkv.hf_runner import import_and_decode, reference_decode  # noqa: E402
from xvkv.identity import identity_from_model_dir  # noqa: E402
from xvkv.wire import HandoffError, read_handoff  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", required=True)
    ap.add_argument("--handoffs", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--device", default="hpu")
    ap.add_argument("--max-new-tokens", type=int, default=128)
    ap.add_argument("--skip-reference", action="store_true")
    args = ap.parse_args()

    from transformers import AutoModelForCausalLM, AutoTokenizer

    device = resolve_device(args.device)
    tok = AutoTokenizer.from_pretrained(args.model)
    model = AutoModelForCausalLM.from_pretrained(args.model, dtype=torch.bfloat16).to(device).eval()
    identity = identity_from_model_dir(args.model)
    adapter = HFCacheAdapter(identity, "intel", "transformers")
    del tok  # tokenizer only checked for load errors; hashes come from identity
    eos = None  # fixed-length outputs keep the drift comparison fair

    out = Path(args.out)
    (out / "logits").mkdir(parents=True, exist_ok=True)
    cross_f = (out / "cross.jsonl").open("w")
    ref_f = None if args.skip_reference else (out / "reference.jsonl").open("w")

    for path in sorted(Path(args.handoffs).glob("*.xvkv")):
        header, frames = read_handoff(path)
        rid = header.request_id
        try:
            t0 = time.perf_counter()
            cross = import_and_decode(model, adapter, header, frames, device,
                                      args.max_new_tokens, eos)
            t1 = time.perf_counter()
        except HandoffError as e:
            print(f"{rid}: REFUSED — {e}")
            continue
        cross_f.write(json.dumps({"id": rid, "tokens": cross.tokens,
                                  "seconds": t1 - t0}) + "\n")
        torch.save(cross.first_step_logits, out / "logits" / f"{rid}.cross.pt")

        if ref_f:
            t2 = time.perf_counter()
            ref = reference_decode(model, header.token_ids, device, args.max_new_tokens, eos)
            t3 = time.perf_counter()
            ref_f.write(json.dumps({"id": rid, "tokens": ref.tokens,
                                    "seconds": t3 - t2}) + "\n")
            torch.save(ref.first_step_logits, out / "logits" / f"{rid}.reference.pt")
        print(f"{rid}: decoded {len(cross.tokens)} tokens in {t1 - t0:.3f}s")

    cross_f.close()
    if ref_f:
        ref_f.close()


if __name__ == "__main__":
    main()
