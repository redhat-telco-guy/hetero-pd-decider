"""Neutral wire format for a KV-cache handoff between engines/vendors.

A handoff is: one header, then one LayerFrame per layer (in layer order).
Tensors are always moved through host memory in this format, so neither side
ever needs to know the other's paged layout.
"""

from __future__ import annotations

import json
import struct
import zlib
from dataclasses import asdict, dataclass, field
from typing import Optional

import torch

WIRE_VERSION = 1

# Wire dtypes are named explicitly so a header never depends on torch's repr.
_DTYPES = {
    "bf16": torch.bfloat16,
    "fp16": torch.float16,
    "fp32": torch.float32,
}
_DTYPE_NAMES = {v: k for k, v in _DTYPES.items()}


def dtype_from_name(name: str) -> torch.dtype:
    try:
        return _DTYPES[name]
    except KeyError as e:
        raise HandoffError(f"unsupported wire dtype {name!r}") from e


def dtype_name(dtype: torch.dtype) -> str:
    try:
        return _DTYPE_NAMES[dtype]
    except KeyError as e:
        raise HandoffError(f"unsupported wire dtype {dtype}") from e


class HandoffError(Exception):
    """Raised when a handoff must be refused (mismatch, corruption, bad frame)."""


@dataclass
class ModelIdentity:
    """Fields BOTH sides must agree on exactly, or the handoff is refused."""

    model_hash: str
    tokenizer_hash: str
    rope_hash: str
    num_layers: int
    num_kv_heads: int
    head_dim: int
    dtype: str = "bf16"

    def mismatches(self, other: "ModelIdentity") -> list[str]:
        mine, theirs = asdict(self), asdict(other)
        return [f"{k}: producer={theirs[k]!r} consumer={mine[k]!r}"
                for k in mine if mine[k] != theirs[k]]


@dataclass
class KVHeader:
    request_id: str
    token_ids: list[int]
    first_output_token: int
    identity: ModelIdentity
    producer_vendor: str = "unknown"      # e.g. "nvidia"
    producer_engine: str = "unknown"      # e.g. "vllm-0.x.y"
    wire_version: int = WIRE_VERSION
    extra: dict = field(default_factory=dict)

    @property
    def seq_len(self) -> int:
        return len(self.token_ids)

    def to_bytes(self) -> bytes:
        d = asdict(self)
        return json.dumps(d, separators=(",", ":")).encode()

    @classmethod
    def from_bytes(cls, b: bytes) -> "KVHeader":
        d = json.loads(b.decode())
        d["identity"] = ModelIdentity(**d["identity"])
        hdr = cls(**d)
        if hdr.wire_version != WIRE_VERSION:
            raise HandoffError(
                f"wire version {hdr.wire_version} != supported {WIRE_VERSION}")
        return hdr


def checksum(t: torch.Tensor) -> int:
    """CRC32 over the raw bytes of a contiguous CPU tensor."""
    t = t.detach().contiguous().cpu()
    return zlib.crc32(t.view(torch.uint8).numpy().tobytes()) & 0xFFFFFFFF


@dataclass
class LayerFrame:
    """K and V for one layer in canonical form: [seq_len, kv_heads, head_dim]."""

    layer_idx: int
    k: torch.Tensor
    v: torch.Tensor
    k_crc: Optional[int] = None
    v_crc: Optional[int] = None

    def seal(self) -> "LayerFrame":
        self.k = self.k.detach().contiguous().cpu()
        self.v = self.v.detach().contiguous().cpu()
        self.k_crc = checksum(self.k)
        self.v_crc = checksum(self.v)
        return self

    # --- byte encoding (meta + raw K bytes + raw V bytes) -------------------
    _META = struct.Struct("<IIIIII")  # layer, seq, heads, dim, k_crc, v_crc

    def to_parts(self) -> list[bytes]:
        if self.k_crc is None:
            self.seal()
        s, h, d = self.k.shape
        meta = self._META.pack(self.layer_idx, s, h, d, self.k_crc, self.v_crc)
        return [meta,
                self.k.view(torch.uint8).numpy().tobytes(),
                self.v.view(torch.uint8).numpy().tobytes()]

    @classmethod
    def from_parts(cls, parts: list[bytes], dtype: torch.dtype) -> "LayerFrame":
        if len(parts) != 3:
            raise HandoffError(f"layer frame needs 3 parts, got {len(parts)}")
        layer, s, h, d, k_crc, v_crc = cls._META.unpack(parts[0])

        def _tensor(raw: bytes) -> torch.Tensor:
            t = torch.frombuffer(bytearray(raw), dtype=torch.uint8)
            return t.view(dtype).reshape(s, h, d)

        return cls(layer, _tensor(parts[1]), _tensor(parts[2]), k_crc, v_crc)

    def verify(self, header: KVHeader) -> None:
        """Refuse the frame if its shape or bytes don't match the header."""
        idn = header.identity
        want = (header.seq_len, idn.num_kv_heads, idn.head_dim)
        for name, t, crc in (("K", self.k, self.k_crc), ("V", self.v, self.v_crc)):
            if tuple(t.shape) != want:
                raise HandoffError(
                    f"layer {self.layer_idx} {name} shape {tuple(t.shape)} != {want}")
            if t.dtype != dtype_from_name(idn.dtype):
                raise HandoffError(
                    f"layer {self.layer_idx} {name} dtype {t.dtype} != {idn.dtype}")
            if crc is None or checksum(t) != crc:
                raise HandoffError(f"layer {self.layer_idx} {name} checksum mismatch")
        if not 0 <= self.layer_idx < idn.num_layers:
            raise HandoffError(f"layer index {self.layer_idx} out of range")


_LEN = struct.Struct("<Q")
_MAGIC = b"XVKV"


def write_handoff(path, header: KVHeader, frames) -> int:
    """Write a whole handoff to a file (phase-2 offline proof). Returns bytes."""
    n = 0
    with open(path, "wb") as f:
        def put(b: bytes):
            nonlocal n
            f.write(_LEN.pack(len(b)))
            f.write(b)
            n += _LEN.size + len(b)
        f.write(_MAGIC)
        put(header.to_bytes())
        for fr in frames:
            for part in fr.to_parts():
                put(part)
    return n + len(_MAGIC)


def read_handoff(path) -> tuple[KVHeader, list[LayerFrame]]:
    with open(path, "rb") as f:
        if f.read(4) != _MAGIC:
            raise HandoffError(f"{path}: not an xvkv handoff file")

        def get() -> Optional[bytes]:
            raw = f.read(_LEN.size)
            if not raw:
                return None
            (size,) = _LEN.unpack(raw)
            return f.read(size)

        header = KVHeader.from_bytes(get())
        dtype = dtype_from_name(header.identity.dtype)
        frames = []
        while True:
            meta = get()
            if meta is None:
                break
            frames.append(LayerFrame.from_parts([meta, get(), get()], dtype))
    return header, frames


def validate_header(header: KVHeader, consumer: ModelIdentity,
                    max_seq_len: Optional[int] = None) -> None:
    """Consumer-side gate: refuse any identity mismatch before touching memory."""
    bad = consumer.mismatches(header.identity)
    if bad:
        raise HandoffError("identity mismatch -> " + "; ".join(bad))
    if header.seq_len == 0:
        raise HandoffError("empty prompt")
    if max_seq_len is not None and header.seq_len >= max_seq_len:
        raise HandoffError(
            f"seq_len {header.seq_len} leaves no room to decode (max {max_seq_len})")
