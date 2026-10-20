"""Paged KV-cache layouts and the generic gather/scatter between them.

An engine stores each layer's KV cache in fixed-size blocks. Where a token
lives is (block_id, offset) with block_id taken from that request's block
table. Engines differ in block size and in axis order, so a layout is
described by a LayoutSpec, and ONE pair of functions handles every engine:

    gather_layer:  paged cache  ->  canonical [seq_len, kv_heads, head_dim]
    scatter_layer: canonical    ->  paged cache (in place)

Axis letters used in a spec:
    K  the K/V axis (size 2) in a stacked tensor
    N  block index
    B  offset inside a block (size = block_size)
    S  flattened slot = block * block_size + offset (block-major)
    H  KV head
    D  head dim

The defaults below are STARTING ASSUMPTIONS for each engine. Run
scripts/probe_kv_layout.py on each node and pass the printed spec instead of
trusting these: backends and plugin versions change their layouts.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Sequence, Union

import torch

LayerCache = Union[torch.Tensor, tuple[torch.Tensor, torch.Tensor]]

_STACKED_AXES = ("KNBHD", "NKBHD", "KNHBD")      # one tensor holding K and V
_SEPARATE_AXES = ("NBHD", "NHBD", "SHD")          # (K tensor, V tensor)


@dataclass(frozen=True)
class LayoutSpec:
    name: str
    block_size: int
    axes: str            # e.g. "KNBHD" (stacked) or "SHD" (separate)

    @property
    def stacked(self) -> bool:
        return "K" in self.axes

    def __post_init__(self):
        if self.axes not in _STACKED_AXES + _SEPARATE_AXES:
            raise ValueError(f"unsupported axes {self.axes!r}")
        if self.block_size <= 0:
            raise ValueError("block_size must be positive")


# ---- starting assumptions per engine (verify with the probe script) --------
VLLM_CUDA_FLASH_ATTN = LayoutSpec("vllm-cuda-flash-attn", block_size=16, axes="KNBHD")
VLLM_CUDA_FLASHINFER = LayoutSpec("vllm-cuda-flashinfer", block_size=16, axes="NKBHD")
VLLM_GAUDI = LayoutSpec("vllm-gaudi", block_size=128, axes="SHD")


def _split(cache: LayerCache, spec: LayoutSpec) -> tuple[torch.Tensor, torch.Tensor, str]:
    """Return (K view, V view, per-tensor axes) for either storage style."""
    if spec.stacked:
        if not isinstance(cache, torch.Tensor):
            raise TypeError(f"{spec.name}: expected one stacked tensor")
        kpos = spec.axes.index("K")
        if cache.shape[kpos] != 2:
            raise ValueError(f"{spec.name}: K/V axis has size {cache.shape[kpos]}, not 2")
        k = cache.select(kpos, 0)
        v = cache.select(kpos, 1)
        return k, v, spec.axes.replace("K", "")
    if isinstance(cache, torch.Tensor):
        raise TypeError(f"{spec.name}: expected a (K, V) tuple")
    k, v = cache
    return k, v, spec.axes


def _to_nbhd(t: torch.Tensor, axes: str, block_size: int) -> torch.Tensor:
    """View any supported per-tensor layout as [N, B, H, D] (no copy)."""
    if axes == "NBHD":
        return t
    if axes == "NHBD":
        return t.permute(0, 2, 1, 3)
    if axes == "SHD":
        s, h, d = t.shape
        if s % block_size:
            raise ValueError(f"{s} slots is not a multiple of block size {block_size}")
        return t.view(s // block_size, block_size, h, d)
    raise ValueError(axes)


def _token_index(block_ids: Sequence[int], seq_len: int, block_size: int,
                 device: torch.device) -> tuple[torch.Tensor, torch.Tensor]:
    needed = -(-seq_len // block_size)
    if len(block_ids) < needed:
        raise ValueError(f"{seq_len} tokens need {needed} blocks, got {len(block_ids)}")
    pos = torch.arange(seq_len, device=device)
    table = torch.as_tensor(list(block_ids[:needed]), device=device, dtype=torch.long)
    return table[pos // block_size], pos % block_size


def gather_layer(cache: LayerCache, spec: LayoutSpec, block_ids: Sequence[int],
                 seq_len: int) -> tuple[torch.Tensor, torch.Tensor]:
    """Paged cache -> canonical (K, V), each [seq_len, H, D] on the cache's device."""
    k, v, axes = _split(cache, spec)
    k4 = _to_nbhd(k, axes, spec.block_size)
    v4 = _to_nbhd(v, axes, spec.block_size)
    blk, off = _token_index(block_ids, seq_len, spec.block_size, k4.device)
    return k4[blk, off].contiguous(), v4[blk, off].contiguous()


def scatter_layer(cache: LayerCache, spec: LayoutSpec, block_ids: Sequence[int],
                  k_canon: torch.Tensor, v_canon: torch.Tensor) -> None:
    """Canonical (K, V) -> paged cache, written in place into block_ids.

    Only the first seq_len slots are written; the tail of the last block is
    left untouched, which is what the engine expects for a partial block.
    """
    k, v, axes = _split(cache, spec)
    k4 = _to_nbhd(k, axes, spec.block_size)
    v4 = _to_nbhd(v, axes, spec.block_size)
    seq_len = k_canon.shape[0]
    if tuple(k_canon.shape[1:]) != tuple(k4.shape[2:]):
        raise ValueError(f"head shape {tuple(k_canon.shape[1:])} != cache {tuple(k4.shape[2:])}")
    blk, off = _token_index(block_ids, seq_len, spec.block_size, k4.device)
    k4[blk, off] = k_canon.to(device=k4.device, dtype=k4.dtype)
    v4[blk, off] = v_canon.to(device=v4.device, dtype=v4.dtype)


def blocks_needed(seq_len: int, spec: LayoutSpec, reserve_decode_tokens: int = 0) -> int:
    """Blocks the consumer must allocate before scatter (prompt + decode room)."""
    return -(-(seq_len + reserve_decode_tokens) // spec.block_size)


def infer_spec(cache: LayerCache, num_kv_heads: int, head_dim: int, block_size: int,
               name: str = "probed") -> LayoutSpec:
    """Infer a LayoutSpec from one layer's real cache tensor(s).

    Raises if zero or several candidate layouts fit the observed shape, so an
    ambiguous probe is never silently trusted.
    """
    hits = []
    if isinstance(cache, torch.Tensor):
        shape = tuple(cache.shape)
        for axes in _STACKED_AXES:
            if len(axes) != len(shape):
                continue
            fixed = {"K": 2, "B": block_size, "H": num_kv_heads, "D": head_dim}
            if all(fixed.get(a, size) == size for a, size in zip(axes, shape)):
                hits.append(axes)
    else:
        shape = tuple(cache[0].shape)
        for axes in _SEPARATE_AXES:
            if len(axes) != len(shape):
                continue
            fixed = {"B": block_size, "H": num_kv_heads, "D": head_dim}
            ok = all(fixed.get(a, size) == size for a, size in zip(axes, shape))
            if axes == "SHD":
                ok = ok and shape[0] % block_size == 0
            if ok:
                hits.append(axes)
    if len(hits) != 1:
        raise ValueError(f"cannot infer layout from shape {shape} "
                         f"(H={num_kv_heads}, D={head_dim}, block={block_size}): "
                         f"candidates {hits or 'none'}")
    return LayoutSpec(name, block_size, hits[0])
