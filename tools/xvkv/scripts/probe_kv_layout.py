#!/usr/bin/env python3
"""Print the REAL paged KV-cache layout of a running vLLM engine.

Run once on each node, with the same vLLM version you will serve with:

    # A30
    VLLM_ENABLE_V1_MULTIPROCESSING=0 python scripts/probe_kv_layout.py \
        --model /models/Llama-3.1-8B-Instruct
    # Gaudi 3 (vllm-gaudi plugin installed)
    VLLM_ENABLE_V1_MULTIPROCESSING=0 PT_HPU_LAZY_MODE=1 python scripts/probe_kv_layout.py \
        --model /models/Llama-3.1-8B-Instruct

It prints each layer's cache shape/dtype and the LayoutSpec that
xvkv.layout.infer_spec derives from it. Paste that spec into the connector
config instead of trusting the defaults in layout.py.

vLLM internals move between releases, so this walks several known attribute
paths and reports which one worked. If none does, it prints the worker's
attributes so you can find the cache by hand.
"""

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from xvkv.identity import identity_from_model_dir  # noqa: E402
from xvkv.layout import infer_spec  # noqa: E402

CANDIDATE_PATHS = [
    "model_runner.kv_caches",
    "worker.model_runner.kv_caches",
    "kv_cache",
    "model_runner.kv_cache",
    "cache_engine.gpu_cache",
]


def _probe(worker):
    """Runs inside the worker via collective_rpc; returns plain data only."""
    for path in CANDIDATE_PATHS:
        obj = worker
        try:
            for part in path.split("."):
                obj = getattr(obj, part)
        except AttributeError:
            continue
        if isinstance(obj, dict):
            obj = list(obj.values())
        if isinstance(obj, (list, tuple)) and obj:
            first = obj[0]
            if isinstance(first, (list, tuple)):
                shape = [tuple(t.shape) for t in first]
                dtype, device = str(first[0].dtype), str(first[0].device)
                kind = "separate"
            else:
                shape, dtype, device = tuple(first.shape), str(first.dtype), str(first.device)
                kind = "stacked"
            block = getattr(getattr(worker, "cache_config", None), "block_size", None)
            return {"path": path, "num_layers": len(obj), "kind": kind,
                    "shape": shape, "dtype": dtype, "device": device,
                    "block_size": block}
    return {"path": None, "worker_attrs": sorted(a for a in dir(worker)
                                                  if not a.startswith("__"))}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", required=True)
    ap.add_argument("--max-model-len", type=int, default=4096)
    ap.add_argument("--block-size", type=int, default=None,
                    help="override if the probe cannot read cache_config")
    args = ap.parse_args()

    from vllm import LLM

    llm = LLM(model=args.model, dtype="bfloat16", max_model_len=args.max_model_len,
              enforce_eager=True, gpu_memory_utilization=0.85)
    info = llm.collective_rpc(_probe)[0]
    print("raw probe:", info)
    if info.get("path") is None:
        print("Cache not found on known paths; see worker_attrs above.")
        return

    import torch
    idn = identity_from_model_dir(args.model)
    block = args.block_size or info["block_size"]
    if info["kind"] == "separate":
        fake = tuple(torch.empty(s, device="meta") for s in info["shape"])
    else:
        fake = torch.empty(info["shape"], device="meta")
    spec = infer_spec(fake, idn.num_kv_heads, idn.head_dim, block, name="probed")
    print(f"\nLayoutSpec(name='probed', block_size={spec.block_size}, axes='{spec.axes}')")


if __name__ == "__main__":
    main()
