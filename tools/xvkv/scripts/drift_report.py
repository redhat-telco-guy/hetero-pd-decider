#!/usr/bin/env python3
"""PHASE 2 verdict: compare cross-vendor decode against Gaudi-only reference.

    python scripts/drift_report.py results/ [--prefix 64] [--pass-rate 0.95]

Pass criterion from the project plan: identical first 64 tokens on >= 95% of
prompts. Also reports first-divergence positions and first-step logit KL.
"""

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import torch  # noqa: E402

from xvkv.drift import compare, summarize  # noqa: E402


def load(path: Path) -> dict:
    return {r["id"]: r for r in map(json.loads, path.read_text().splitlines()) if r}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("results")
    ap.add_argument("--prefix", type=int, default=64)
    ap.add_argument("--pass-rate", type=float, default=0.95)
    args = ap.parse_args()

    res = Path(args.results)
    cross, ref = load(res / "cross.jsonl"), load(res / "reference.jsonl")
    out = []
    for rid in sorted(set(cross) & set(ref)):
        lc = res / "logits" / f"{rid}.cross.pt"
        lr = res / "logits" / f"{rid}.reference.pt"
        r = compare(rid, ref[rid]["tokens"], cross[rid]["tokens"], args.prefix,
                    torch.load(lr) if lr.exists() else None,
                    torch.load(lc) if lc.exists() else None)
        out.append(r)
        print(f"{rid:>20}  first divergence: {r.first_divergence!s:>5}  "
              f"KL: {r.kl_first_step if r.kl_first_step is None else f'{r.kl_first_step:.2e}'}")
    summary = summarize(out, args.prefix, args.pass_rate)
    print(json.dumps(summary, indent=2))
    (res / "drift_summary.json").write_text(json.dumps(summary, indent=2))
    sys.exit(0 if summary["passed"] else 1)


if __name__ == "__main__":
    main()
