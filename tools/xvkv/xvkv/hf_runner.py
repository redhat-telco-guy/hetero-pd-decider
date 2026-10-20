"""Phase-2 offline proof with Hugging Face transformers.

Runs the same model on each vendor with no paging involved, so any output
difference comes from cross-vendor numerics, not from layout bugs:

    A30:    prefill -> export KV to a handoff file
    Gaudi:  import KV -> greedy decode           ("cross" run)
    Gaudi:  prefill + greedy decode locally      ("reference" run)
    then:   drift between cross and reference
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Optional, Sequence

import torch

from .adapters import HFCacheAdapter, hpu_sync


@dataclass
class DecodeOutput:
    tokens: list[int]                       # first token + generated tokens
    first_step_logits: torch.Tensor         # logits that chose tokens[1], on CPU


def encode_chat(tok, text: str) -> list[int]:
    """Chat-template a single user turn to token ids (handles the dict return
    that newer transformers versions give)."""
    out = tok.apply_chat_template([{"role": "user", "content": text}],
                                  add_generation_prompt=True)
    if hasattr(out, "keys"):
        out = out["input_ids"]
    if out and isinstance(out[0], list):
        out = out[0]
    return list(out)


def _sync(device: torch.device) -> None:
    if device.type == "hpu":
        hpu_sync()


@torch.inference_mode()
def prefill(model, token_ids: Sequence[int], device: torch.device):
    """Return (cache, first_output_token, last_logits_cpu)."""
    from transformers import DynamicCache

    ids = torch.tensor([list(token_ids)], device=device)
    cache = DynamicCache()
    out = model(input_ids=ids, past_key_values=cache, use_cache=True)
    _sync(device)
    logits = out.logits[0, -1].float().cpu()
    return out.past_key_values, int(logits.argmax()), logits


@torch.inference_mode()
def greedy_decode(model, cache, first_token: int, max_new_tokens: int,
                  device: torch.device, eos_ids: Optional[set[int]] = None) -> DecodeOutput:
    tokens = [first_token]
    first_logits = None
    cur = first_token
    for _ in range(max_new_tokens):
        out = model(input_ids=torch.tensor([[cur]], device=device),
                    past_key_values=cache, use_cache=True)
        _sync(device)
        logits = out.logits[0, -1].float()
        if first_logits is None:
            first_logits = logits.cpu()
        cur = int(logits.argmax())
        tokens.append(cur)
        cache = out.past_key_values
        if eos_ids and cur in eos_ids:
            break
    return DecodeOutput(tokens, first_logits)


def export_prefill(model, adapter: HFCacheAdapter, token_ids: Sequence[int],
                   device: torch.device, request_id: str):
    cache, first, _ = prefill(model, token_ids, device)
    return adapter.export(cache, token_ids, first, request_id=request_id)


def import_and_decode(model, adapter: HFCacheAdapter, header, frames,
                      device: torch.device, max_new_tokens: int,
                      eos_ids: Optional[set[int]] = None) -> DecodeOutput:
    dtype = next(model.parameters()).dtype
    cache = adapter.import_(header, frames, device, dtype)
    return greedy_decode(model, cache, header.first_output_token, max_new_tokens,
                         device, eos_ids)


def reference_decode(model, token_ids: Sequence[int], device: torch.device,
                     max_new_tokens: int, eos_ids: Optional[set[int]] = None) -> DecodeOutput:
    cache, first, _ = prefill(model, token_ids, device)
    return greedy_decode(model, cache, first, max_new_tokens, device, eos_ids)
