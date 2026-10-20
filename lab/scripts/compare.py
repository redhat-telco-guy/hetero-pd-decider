#!/usr/bin/env python3
"""Compare loadtest.py runs: TTFT and inter-token latency per request class.

  python compare.py stock=run-stock.csv hetero=run-hetero.csv
"""

from __future__ import annotations

import csv
import sys

from oai import percentile


def load(path: str) -> list[dict]:
    with open(path) as f:
        return list(csv.DictReader(f))


def nums(rows: list[dict], key: str) -> list[float]:
    return [float(r[key]) for r in rows if r[key] not in ("", None)]


def summarize(rows: list[dict]) -> dict[str, dict]:
    out = {}
    for cls in sorted({r["cls"] for r in rows}) + ["all"]:
        sel = rows if cls == "all" else [r for r in rows if r["cls"] == cls]
        ok = [r for r in sel if not r["error"]]
        span = max((float(r["start_s"]) + float(r["e2e_ms"]) / 1000 for r in ok), default=0) - \
            min((float(r["start_s"]) for r in ok), default=0)
        tokens = sum(int(r["completion_tokens"] or 0) for r in ok)
        out[cls] = {
            "n": len(sel), "errors": len(sel) - len(ok),
            "ttft_p50": percentile(nums(ok, "ttft_ms"), 50),
            "ttft_p95": percentile(nums(ok, "ttft_ms"), 95),
            "itl_p50": percentile(nums(ok, "itl_mean_ms"), 50),
            "itl_p95": percentile(nums(ok, "itl_p95_ms"), 95),
            "out_tok_s": tokens / span if span > 0 else 0.0,
        }
    return out


def main() -> None:
    runs = [arg.split("=", 1) for arg in sys.argv[1:]]
    if len(runs) < 1:
        sys.exit(__doc__)
    summaries = {name: summarize(load(path)) for name, path in runs}
    classes = sorted({c for s in summaries.values() for c in s}, key=lambda c: (c == "all", c))
    header = f"{'class':6} {'run':10} {'n':>5} {'err':>4} {'TTFT p50':>9} {'TTFT p95':>9} " \
             f"{'ITL p50':>8} {'ITL p95':>8} {'out tok/s':>10}"
    print(header)
    print("-" * len(header))
    for cls in classes:
        for name, s in summaries.items():
            if cls not in s:
                continue
            m = s[cls]
            print(f"{cls:6} {name:10} {m['n']:5d} {m['errors']:4d} {m['ttft_p50']:9.0f} "
                  f"{m['ttft_p95']:9.0f} {m['itl_p50']:8.1f} {m['itl_p95']:8.1f} {m['out_tok_s']:10.0f}")
    print("\nTTFT and ITL in ms. ITL p50 is the median of per-request mean inter-token latency;"
          " ITL p95 is the 95th percentile of per-request p95.")


if __name__ == "__main__":
    main()
