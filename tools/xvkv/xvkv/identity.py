"""Build a ModelIdentity from a Hugging Face model directory.

Both the prefill (A30) and decode (Gaudi) sides compute this from their own
copy of the model files. If any field differs, the handoff is refused: a KV
cache from different weights, tokenizer or rotary settings decodes to garbage
without raising an error, so this check is the only protection.
"""

from __future__ import annotations

import hashlib
import json
from pathlib import Path

from .wire import ModelIdentity

_ROPE_KEYS = ("rope_theta", "rope_scaling", "max_position_embeddings",
              "partial_rotary_factor", "head_dim", "rope_type")
_TOKENIZER_FILES = ("tokenizer.json", "tokenizer.model", "tokenizer_config.json",
                    "special_tokens_map.json")


def _sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()[:16]


def _canonical_json(obj) -> bytes:
    return json.dumps(obj, sort_keys=True, separators=(",", ":")).encode()


def _weights_fingerprint(model_dir: Path, full: bool) -> bytes:
    """Fast default: weight file names + sizes (+ safetensors index).
    full=True hashes every weight byte (slow for 16 GB, use once per release)."""
    h = hashlib.sha256()
    files = sorted(p for p in model_dir.iterdir()
                   if p.suffix in (".safetensors", ".bin") and p.is_file())
    for p in files:
        h.update(p.name.encode())
        h.update(str(p.stat().st_size).encode())
        if full:
            with p.open("rb") as f:
                for chunk in iter(lambda: f.read(1 << 24), b""):
                    h.update(chunk)
    idx = model_dir / "model.safetensors.index.json"
    if idx.exists():
        h.update(idx.read_bytes())
    return h.digest()


def identity_from_model_dir(model_dir: str | Path, dtype: str = "bf16",
                            full_weight_hash: bool = False) -> ModelIdentity:
    model_dir = Path(model_dir)
    cfg = json.loads((model_dir / "config.json").read_text())
    text_cfg = cfg.get("text_config", cfg)  # multimodal configs nest the LM

    num_layers = text_cfg["num_hidden_layers"]
    num_heads = text_cfg["num_attention_heads"]
    num_kv_heads = text_cfg.get("num_key_value_heads", num_heads)
    head_dim = text_cfg.get("head_dim") or text_cfg["hidden_size"] // num_heads

    model_hash = _sha(_canonical_json(text_cfg) +
                      _weights_fingerprint(model_dir, full_weight_hash))

    tok = hashlib.sha256()
    for name in _TOKENIZER_FILES:
        p = model_dir / name
        if p.exists():
            tok.update(name.encode())
            tok.update(p.read_bytes())
    tokenizer_hash = tok.hexdigest()[:16]

    rope = {k: text_cfg.get(k) for k in _ROPE_KEYS}
    rope_hash = _sha(_canonical_json(rope))

    return ModelIdentity(model_hash=model_hash, tokenizer_hash=tokenizer_hash,
                         rope_hash=rope_hash, num_layers=num_layers,
                         num_kv_heads=num_kv_heads, head_dim=head_dim, dtype=dtype)


def kv_bytes_per_token(idn: ModelIdentity) -> int:
    """K+V bytes per token across all layers (128 KiB for Llama-3.1-8B in bf16)."""
    elem = {"bf16": 2, "fp16": 2, "fp32": 4}[idn.dtype]
    return 2 * idn.num_layers * idn.num_kv_heads * idn.head_dim * elem
