#!/usr/bin/env python3
"""Measure prefill throughput per accelerator class for the decider's profiles.

Hit each engine directly (not the router), one at a time, with no other load:

  oc port-forward deploy/prefill-a30 18000:8000 &
  oc port-forward deploy/decode-gaudi3 18200:8200 &      # the engine port, not the sidecar
  python profile_prefill.py --model meta-llama/Llama-3.1-8B-Instruct \
      --target nvidia-a30=http://localhost:18000 \
      --target intel-gaudi3=http://localhost:18200

Throughput is 1 / slope of time-to-first-token against prompt tokens, which
removes fixed per-request overhead. Prints a profiles block for hetero.values.yaml.
"""

from __future__ import annotations

import argparse
import random
import statistics
import sys

from oai import make_prompt, stream_completion


def fit_slope(xs: list[float], ys: list[float]) -> tuple[float, float]:
    mx, my = statistics.fmean(xs), statistics.fmean(ys)
    sxx = sum((x - mx) ** 2 for x in xs)
    slope = sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / sxx
    return slope, my - slope * mx


def profile(url: str, model: str, sizes: list[int], reps: int, rng: random.Random) -> dict:
    # Warm up so graph compilation (Gaudi) and CUDA graphs are not timed.
    for n in sizes:
        stream_completion(url, model, make_prompt(n, rng), max_tokens=1)
    xs, ys = [], []
    for n in sizes:
        samples = []
        for _ in range(reps):
            r = stream_completion(url, model, make_prompt(n, rng), max_tokens=1)
            if not r.ok:
                sys.exit(f"{url}: request failed: {r.error}")
            samples.append((r.prompt_tokens, r.ttft_s))
        tokens = statistics.median(s[0] for s in samples)
        ttft = statistics.median(s[1] for s in samples)
        xs.append(tokens)
        ys.append(ttft)
        print(f"  {url}: {int(tokens):5d} prompt tokens -> TTFT {ttft * 1000:8.1f} ms", file=sys.stderr)
    slope, intercept = fit_slope(xs, ys)
    return {"tokens_per_sec": 1.0 / slope, "overhead_ms": intercept * 1000}


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", required=True)
    ap.add_argument("--target", action="append", required=True, help="class=url")
    ap.add_argument("--sizes", default="256,1024,2048,4096", help="prompt words")
    ap.add_argument("--reps", type=int, default=3)
    ap.add_argument("--seed", type=int, default=7)
    args = ap.parse_args()

    rng = random.Random(args.seed)
    sizes = [int(s) for s in args.sizes.split(",")]
    results = {}
    for spec in args.target:
        cls, url = spec.split("=", 1)
        print(f"profiling {cls} at {url}", file=sys.stderr)
        results[cls] = profile(url, args.model, sizes, args.reps, rng)

    print("profiles:")
    for cls, r in results.items():
        print(f"  {cls}:")
        print(f"    prefillTokensPerSec: {r['tokens_per_sec']:.0f}   # fixed overhead {r['overhead_ms']:.0f} ms")


if __name__ == "__main__":
    main()
