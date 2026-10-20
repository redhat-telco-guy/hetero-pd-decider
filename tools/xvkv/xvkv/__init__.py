"""xvkv — cross-vendor KV cache handoff for prefill/decode disaggregation.

Every engine converts its own KV cache to and from ONE neutral wire format:

    per layer: K, V as contiguous tensors [seq_len, num_kv_heads, head_dim]
               (no padding, token order, post-rotary K, dtype from the header)

Modules
-------
wire        header, frames, checksums, (de)serialization of the wire format
identity    model / tokenizer / rope hashes that both sides must agree on
layout      LayoutSpec + generic paged-cache gather/scatter
adapters    engine adapters: vLLM-CUDA (A30), vLLM-Gaudi (Gaudi 3), HF transformers
transport   host-staged ZeroMQ streaming, layer by layer
drift       correctness metrics between single-vendor and cross-vendor runs
"""

__version__ = "0.1.0"
