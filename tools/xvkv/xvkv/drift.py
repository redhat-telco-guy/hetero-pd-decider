"""Correctness metrics: cross-vendor decode vs. single-vendor decode.

Bit-identical output is not expected: NVIDIA and Gaudi kernels round BF16
differently, and greedy decoding eventually diverges on long outputs. What
matters is HOW EARLY outputs diverge and how far the logits move.
These numbers are also the Dual-Key canary signal for the router.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Optional, Sequence

import torch


@dataclass
class DriftResult:
    request_id: str
    first_divergence: Optional[int]   # index of first differing token, None = identical
    compared: int
    exact_prefix_ok: bool             # identical for the first `prefix` tokens
    kl_first_step: Optional[float]    # KL(ref || test) of the first decode step logits
    top1_agree_first_step: Optional[bool]


def first_divergence(ref: Sequence[int], test: Sequence[int]) -> Optional[int]:
    n = min(len(ref), len(test))
    for i in range(n):
        if ref[i] != test[i]:
            return i
    return None if len(ref) == len(test) else n


def kl_divergence(ref_logits: torch.Tensor, test_logits: torch.Tensor) -> float:
    p = torch.log_softmax(ref_logits.float(), -1)
    q = torch.log_softmax(test_logits.float(), -1)
    return float((p.exp() * (p - q)).sum())


def compare(request_id: str, ref_tokens: Sequence[int], test_tokens: Sequence[int],
            prefix: int = 64, ref_logits: Optional[torch.Tensor] = None,
            test_logits: Optional[torch.Tensor] = None) -> DriftResult:
    div = first_divergence(ref_tokens, test_tokens)
    kl = top1 = None
    if ref_logits is not None and test_logits is not None:
        kl = kl_divergence(ref_logits, test_logits)
        top1 = bool(ref_logits.argmax() == test_logits.argmax())
    return DriftResult(request_id, div, min(len(ref_tokens), len(test_tokens)),
                       div is None or div >= prefix, kl, top1)


def summarize(results: Sequence[DriftResult], prefix: int = 64,
              pass_rate: float = 0.95) -> dict:
    n = len(results)
    ok = sum(r.exact_prefix_ok for r in results)
    divs = [r.first_divergence for r in results if r.first_divergence is not None]
    kls = [r.kl_first_step for r in results if r.kl_first_step is not None]
    return {
        "requests": n,
        f"identical_first_{prefix}": ok,
        "pass_rate": ok / n if n else 0.0,
        "passed": n > 0 and ok / n >= pass_rate,
        "median_first_divergence": sorted(divs)[len(divs) // 2] if divs else None,
        "max_kl_first_step": max(kls) if kls else None,
        "mean_kl_first_step": sum(kls) / len(kls) if kls else None,
    }
