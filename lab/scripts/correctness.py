#!/usr/bin/env python3
"""Cross-vendor correctness: remote-prefill output vs single-vendor output.

Install the router with always.values.yaml so every request through it is
prefilled on the other vendor. Port-forward one decode pod's engine port as
the single-vendor reference (it prefills and decodes locally):

  oc port-forward svc/hetero-pd-epp 8081:80 &
  oc port-forward deploy/decode-gaudi3 18200:8200 &
  python correctness.py --router http://localhost:8081 --reference http://localhost:18200 \
      --model meta-llama/Llama-3.1-8B-Instruct --prompts 200

Greedy decoding on both paths. BF16 rounding differs between vendors, so long
outputs can drift; the pass bar is identical output for the first 64 tokens on
at least 95% of prompts. Low scores with early divergence point at the KV
handoff (layout, block size, rotary), not at rounding.
"""

from __future__ import annotations

import argparse
import random
import statistics
import sys

from oai import make_prompt, stream_completion


def first_divergence(a: str, b: str) -> int | None:
    for i, (x, y) in enumerate(zip(a, b)):
        if x != y:
            return i
    return None if len(a) == len(b) else min(len(a), len(b))


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--router", required=True)
    ap.add_argument("--reference", required=True)
    ap.add_argument("--model", required=True)
    ap.add_argument("--prompts", type=int, default=200)
    ap.add_argument("--prompt-words", type=int, default=1500)
    ap.add_argument("--max-tokens", type=int, default=64)
    ap.add_argument("--pass-rate", type=float, default=0.95)
    ap.add_argument("--seed", type=int, default=11)
    args = ap.parse_args()

    rng = random.Random(args.seed)
    same, divs, failures = 0, [], 0
    for i in range(args.prompts):
        prompt = make_prompt(rng.randint(args.prompt_words // 2, args.prompt_words), rng)
        ref = stream_completion(args.reference, args.model, prompt, args.max_tokens, seed=0)
        got = stream_completion(args.router, args.model, prompt, args.max_tokens, seed=0)
        if not (ref.ok and got.ok):
            failures += 1
            print(f"[{i}] request failed: ref={ref.error!r} router={got.error!r}", file=sys.stderr)
            continue
        d = first_divergence(ref.text, got.text)
        if d is None:
            same += 1
        else:
            divs.append(d)
            print(f"[{i}] diverges at char {d}: ref={ref.text[max(0, d - 20):d + 20]!r} "
                  f"router={got.text[max(0, d - 20):d + 20]!r}", file=sys.stderr)

    compared = args.prompts - failures
    rate = same / compared if compared else 0.0
    print(f"compared {compared} prompts, identical {same} ({rate:.1%}), failed {failures}")
    if divs:
        print(f"divergent: {len(divs)}, median first divergence at char {statistics.median(divs):.0f}")
    passed = compared > 0 and rate >= args.pass_rate
    print("PASS" if passed else "FAIL")
    sys.exit(0 if passed else 1)


if __name__ == "__main__":
    main()
