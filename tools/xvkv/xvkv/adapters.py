"""Engine adapters: convert an engine's KV cache to/from the wire format.

PagedAdapter      vLLM-style paged caches (A30 producer, Gaudi 3 consumer).
                  Takes the per-layer cache list and the request's block table.
HFCacheAdapter    Hugging Face transformers DynamicCache. Used for the phase-2
                  offline proof, which tests cross-vendor numerics without any
                  paging in the way.
"""

from __future__ import annotations

import os
import uuid
from typing import Callable, Iterable, Iterator, Optional, Sequence

import torch

from .layout import LayerCache, LayoutSpec, gather_layer, scatter_layer
from .wire import (HandoffError, KVHeader, LayerFrame, ModelIdentity,
                   dtype_from_name, validate_header)


# ---------------------------------------------------------------------------
# device helpers
# ---------------------------------------------------------------------------
def hpu_sync() -> None:
    """Flush the Gaudi lazy-mode graph if the Habana bridge is loaded.

    In eager mode (PT_HPU_LAZY_MODE=0) this is a no-op. In lazy mode, writes to
    the cache are not materialized until mark_step(), so call this after every
    scatter on Gaudi.
    """
    try:
        import habana_frameworks.torch.core as htcore  # type: ignore
    except ImportError:
        return
    htcore.mark_step()


def default_sync_for(device: torch.device) -> Callable[[], None]:
    if device.type == "hpu":
        return hpu_sync
    if device.type == "cuda":
        return torch.cuda.synchronize
    return lambda: None


# ---------------------------------------------------------------------------
# paged engines (vLLM CUDA on the A30, vLLM Gaudi plugin on Gaudi 3)
# ---------------------------------------------------------------------------
class PagedAdapter:
    def __init__(self, spec: LayoutSpec, identity: ModelIdentity,
                 vendor: str, engine: str,
                 sync: Optional[Callable[[], None]] = None):
        self.spec = spec
        self.identity = identity
        self.vendor = vendor
        self.engine = engine
        self._sync = sync

    # ---- producer side (A30) ---------------------------------------------
    def make_header(self, token_ids: Sequence[int], first_output_token: int,
                    request_id: Optional[str] = None) -> KVHeader:
        return KVHeader(request_id=request_id or uuid.uuid4().hex,
                        token_ids=list(map(int, token_ids)),
                        first_output_token=int(first_output_token),
                        identity=self.identity,
                        producer_vendor=self.vendor,
                        producer_engine=self.engine,
                        extra={"producer_layout": self.spec.name,
                               "producer_block_size": self.spec.block_size})

    def export_layer(self, layer_idx: int, cache: LayerCache,
                     block_ids: Sequence[int], seq_len: int) -> LayerFrame:
        """One layer -> sealed frame in host memory. Call it per layer as prefill
        finishes that layer to overlap the transfer with compute."""
        k, v = gather_layer(cache, self.spec, block_ids, seq_len)
        want = dtype_from_name(self.identity.dtype)
        return LayerFrame(layer_idx, k.to(want), v.to(want)).seal()

    def export_all(self, kv_caches: Sequence[LayerCache], block_ids: Sequence[int],
                   seq_len: int) -> Iterator[LayerFrame]:
        if len(kv_caches) != self.identity.num_layers:
            raise HandoffError(f"{len(kv_caches)} cache layers != "
                               f"{self.identity.num_layers} in identity")
        for i, cache in enumerate(kv_caches):
            yield self.export_layer(i, cache, block_ids, seq_len)

    # ---- consumer side (Gaudi 3) -------------------------------------------
    def import_all(self, header: KVHeader, frames: Iterable[LayerFrame],
                   kv_caches: Sequence[LayerCache], block_ids: Sequence[int],
                   max_seq_len: Optional[int] = None) -> int:
        """Validate, then scatter every layer into the consumer's blocks.

        block_ids must already be allocated by the consumer engine for this
        request (see layout.blocks_needed). Returns the number of tokens now
        cached; the engine resumes decoding at that position with
        header.first_output_token as its next input.
        """
        validate_header(header, self.identity, max_seq_len)
        seen: set[int] = set()
        for frame in frames:
            frame.verify(header)
            if frame.layer_idx in seen:
                raise HandoffError(f"duplicate layer {frame.layer_idx}")
            seen.add(frame.layer_idx)
            scatter_layer(kv_caches[frame.layer_idx], self.spec, block_ids,
                          frame.k, frame.v)
        if len(seen) != self.identity.num_layers:
            missing = sorted(set(range(self.identity.num_layers)) - seen)
            raise HandoffError(f"missing layers {missing[:8]}…")
        if self._sync:
            self._sync()
        return header.seq_len


# ---------------------------------------------------------------------------
# Hugging Face transformers (phase-2 offline proof)
# ---------------------------------------------------------------------------
def _hf_layer_tensors(cache) -> list[tuple[torch.Tensor, torch.Tensor]]:
    """(K, V) per layer, each [batch, kv_heads, seq, head_dim], across
    transformers versions."""
    if hasattr(cache, "layers"):                      # transformers >= 4.56
        return [(l.keys, l.values) for l in cache.layers]
    if hasattr(cache, "key_cache"):                   # older DynamicCache
        return list(zip(cache.key_cache, cache.value_cache))
    return [(k, v) for k, v in cache]                 # legacy tuple-of-tuples


class HFCacheAdapter:
    """Canonical <-> transformers DynamicCache (batch size 1).

    HF stores K post-rotary as [batch, kv_heads, seq, head_dim]; canonical is
    [seq, kv_heads, head_dim], so it is a squeeze + transpose each way.
    """

    def __init__(self, identity: ModelIdentity, vendor: str, engine: str):
        self.identity = identity
        self.vendor = vendor
        self.engine = engine

    def export(self, cache, token_ids: Sequence[int], first_output_token: int,
               request_id: Optional[str] = None) -> tuple[KVHeader, list[LayerFrame]]:
        layers = _hf_layer_tensors(cache)
        if len(layers) != self.identity.num_layers:
            raise HandoffError(f"cache has {len(layers)} layers, identity says "
                               f"{self.identity.num_layers}")
        want = dtype_from_name(self.identity.dtype)
        frames = []
        for i, (k, v) in enumerate(layers):
            if k.shape[0] != 1:
                raise HandoffError("HF adapter supports batch size 1")
            kc = k[0].transpose(0, 1).to(want)       # [seq, H, D]
            vc = v[0].transpose(0, 1).to(want)
            frames.append(LayerFrame(i, kc, vc).seal())
        header = KVHeader(request_id=request_id or uuid.uuid4().hex,
                          token_ids=list(map(int, token_ids)),
                          first_output_token=int(first_output_token),
                          identity=self.identity, producer_vendor=self.vendor,
                          producer_engine=self.engine,
                          extra={"producer_layout": "hf-dynamic-cache"})
        return header, frames

    def import_(self, header: KVHeader, frames: Iterable[LayerFrame],
                device: torch.device, model_dtype: torch.dtype):
        from transformers import DynamicCache

        validate_header(header, self.identity)
        by_layer = {}
        for f in frames:
            f.verify(header)
            by_layer[f.layer_idx] = f
        if len(by_layer) != self.identity.num_layers:
            raise HandoffError("missing layers in handoff")
        cache = DynamicCache()
        for i in range(self.identity.num_layers):
            f = by_layer[i]
            k = f.k.transpose(0, 1).unsqueeze(0).to(device=device, dtype=model_dtype)
            v = f.v.transpose(0, 1).unsqueeze(0).to(device=device, dtype=model_dtype)
            cache.update(k, v, i)
        if device.type == "hpu":
            hpu_sync()
        return cache


def resolve_device(name: str) -> torch.device:
    """'cuda', 'hpu' or 'cpu'. Loads the Habana bridge for 'hpu'."""
    if name == "hpu":
        os.environ.setdefault("PT_HPU_LAZY_MODE", "0")   # eager: simpler to debug
        import habana_frameworks.torch.core  # noqa: F401  (registers the device)
    return torch.device(name)
