"""CPU tests for the translation layer. Run: python -m pytest -q tests/

They simulate the A30 (vLLM CUDA, 16-token blocks, stacked K/V) and Gaudi 3
(vLLM Gaudi, 128-token blocks, flat slots, separate K/V) layouts with random
data, so they run anywhere. Real layouts must still be confirmed with
scripts/probe_kv_layout.py on each node.
"""

import json
import random
import sys
import threading
from dataclasses import replace
from pathlib import Path

import pytest
import torch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from xvkv.adapters import HFCacheAdapter, PagedAdapter  # noqa: E402
from xvkv.drift import compare  # noqa: E402
from xvkv.identity import identity_from_model_dir, kv_bytes_per_token  # noqa: E402
from xvkv.layout import (VLLM_CUDA_FLASH_ATTN, VLLM_CUDA_FLASHINFER, VLLM_GAUDI,  # noqa: E402
                         LayoutSpec, blocks_needed, gather_layer, infer_spec,
                         scatter_layer)
from xvkv.transport import KVReceiver, KVSender  # noqa: E402
from xvkv.wire import (HandoffError, KVHeader, LayerFrame, ModelIdentity,  # noqa: E402
                       read_handoff, write_handoff)

L, H, D = 4, 8, 128            # small layer count, Llama-3.1-8B head shape
IDN = ModelIdentity("m1", "t1", "r1", num_layers=L, num_kv_heads=H, head_dim=D)


def nv_caches(num_blocks=64, spec=VLLM_CUDA_FLASH_ATTN):
    shape = {"KNBHD": (2, num_blocks, spec.block_size, H, D),
             "NKBHD": (num_blocks, 2, spec.block_size, H, D)}[spec.axes]
    return [torch.zeros(shape, dtype=torch.bfloat16) for _ in range(L)]


def gaudi_caches(num_blocks=8):
    s = num_blocks * VLLM_GAUDI.block_size
    return [(torch.zeros(s, H, D, dtype=torch.bfloat16),
             torch.zeros(s, H, D, dtype=torch.bfloat16)) for _ in range(L)]


def fill_prompt(caches, spec, block_ids, seq_len, seed=0):
    """Write a known random prompt KV into the producer cache; return truth."""
    g = torch.Generator().manual_seed(seed)
    truth = []
    for c in caches:
        k = torch.randn(seq_len, H, D, generator=g).to(torch.bfloat16)
        v = torch.randn(seq_len, H, D, generator=g).to(torch.bfloat16)
        scatter_layer(c, spec, block_ids, k, v)
        truth.append((k, v))
    return truth


# ---------------------------------------------------------------- layout ----
@pytest.mark.parametrize("seq_len", [1, 15, 16, 17, 300, 1000])
@pytest.mark.parametrize("nv_spec", [VLLM_CUDA_FLASH_ATTN, VLLM_CUDA_FLASHINFER])
def test_a30_to_gaudi_reblocking(seq_len, nv_spec):
    """16-token scattered blocks on A30 -> 128-token blocks on Gaudi."""
    rng = random.Random(seq_len)
    nv = nv_caches(spec=nv_spec)
    nv_blocks = rng.sample(range(64), blocks_needed(seq_len, nv_spec))
    truth = fill_prompt(nv, nv_spec, nv_blocks, seq_len)

    producer = PagedAdapter(nv_spec, IDN, "nvidia", "vllm-cuda")
    header = producer.make_header(list(range(seq_len)), first_output_token=42)
    frames = list(producer.export_all(nv, nv_blocks, seq_len))

    ga = gaudi_caches()
    ga_blocks = rng.sample(range(8), blocks_needed(seq_len, VLLM_GAUDI))
    consumer = PagedAdapter(VLLM_GAUDI, IDN, "intel", "vllm-gaudi")
    assert consumer.import_all(header, frames, ga, ga_blocks) == seq_len

    for (k, v), cache in zip(truth, ga):
        gk, gv = gather_layer(cache, VLLM_GAUDI, ga_blocks, seq_len)
        assert torch.equal(gk, k) and torch.equal(gv, v)


def test_scatter_leaves_other_blocks_untouched():
    ga = gaudi_caches()
    sentinel = torch.full((128, H, D), 7.0, dtype=torch.bfloat16)
    ga[0][0][5 * 128:6 * 128] = sentinel          # someone else's block 5
    k = torch.randn(200, H, D).to(torch.bfloat16)
    scatter_layer(ga[0], VLLM_GAUDI, [2, 3], k, k)
    assert torch.equal(ga[0][0][5 * 128:6 * 128], sentinel)
    assert torch.count_nonzero(ga[0][0][3 * 128 + 72:4 * 128]) == 0  # partial tail


def test_too_few_blocks_rejected():
    with pytest.raises(ValueError, match="need 2 blocks"):
        gather_layer(gaudi_caches()[0], VLLM_GAUDI, [0], 200)


def test_infer_spec():
    assert infer_spec(nv_caches()[0], H, D, 16).axes == "KNBHD"
    assert infer_spec(nv_caches(spec=VLLM_CUDA_FLASHINFER)[0], H, D, 16).axes == "NKBHD"
    assert infer_spec(gaudi_caches()[0], H, D, 128).axes == "SHD"
    with pytest.raises(ValueError):
        infer_spec(torch.zeros(3, 5, 7), H, D, 16)


# ------------------------------------------------------------------ wire ----
def test_frame_roundtrip_and_tamper():
    k = torch.randn(10, H, D).to(torch.bfloat16)
    f = LayerFrame(0, k, k.clone()).seal()
    parts = f.to_parts()
    hdr = KVHeader("r", list(range(10)), 1, IDN)
    LayerFrame.from_parts(parts, torch.bfloat16).verify(hdr)
    bad = bytearray(parts[1]); bad[100] ^= 0xFF
    with pytest.raises(HandoffError, match="checksum"):
        LayerFrame.from_parts([parts[0], bytes(bad), parts[2]], torch.bfloat16).verify(hdr)


@pytest.mark.parametrize("field,value", [("model_hash", "other"), ("rope_hash", "x"),
                                         ("num_kv_heads", 4), ("dtype", "fp16")])
def test_identity_mismatch_refused(field, value):
    producer = PagedAdapter(VLLM_CUDA_FLASH_ATTN, replace(IDN, **{field: value}), "nvidia", "x")
    consumer = PagedAdapter(VLLM_GAUDI, IDN, "intel", "y")
    hdr = producer.make_header([1, 2, 3], 4)
    with pytest.raises(HandoffError, match="identity mismatch"):
        consumer.import_all(hdr, [], gaudi_caches(), [0])


def test_missing_layer_refused():
    nv = nv_caches(); blocks = [0]
    fill_prompt(nv, VLLM_CUDA_FLASH_ATTN, blocks, 5)
    p = PagedAdapter(VLLM_CUDA_FLASH_ATTN, IDN, "nvidia", "x")
    frames = list(p.export_all(nv, blocks, 5))[:-1]
    c = PagedAdapter(VLLM_GAUDI, IDN, "intel", "y")
    with pytest.raises(HandoffError, match="missing layers"):
        c.import_all(p.make_header(range(5), 0), frames, gaudi_caches(), [0])


def test_handoff_file(tmp_path):
    nv = nv_caches(); blocks = [3, 9]
    truth = fill_prompt(nv, VLLM_CUDA_FLASH_ATTN, blocks, 20)
    p = PagedAdapter(VLLM_CUDA_FLASH_ATTN, IDN, "nvidia", "x")
    write_handoff(tmp_path / "a.xvkv", p.make_header(range(20), 7, "a"),
                  p.export_all(nv, blocks, 20))
    hdr, frames = read_handoff(tmp_path / "a.xvkv")
    assert hdr.request_id == "a" and hdr.first_output_token == 7
    assert torch.equal(frames[2].k, truth[2][0])


def test_kv_bytes_llama8b():
    llama = replace(IDN, num_layers=32)
    assert kv_bytes_per_token(llama) == 128 * 1024


# ------------------------------------------------------------- transport ----
def test_zmq_streaming_handoff():
    seq = 300
    nv = nv_caches(); nv_blocks = list(range(20, 20 + blocks_needed(seq, VLLM_CUDA_FLASH_ATTN)))
    truth = fill_prompt(nv, VLLM_CUDA_FLASH_ATTN, nv_blocks, seq)
    producer = PagedAdapter(VLLM_CUDA_FLASH_ATTN, IDN, "nvidia", "vllm-cuda")
    consumer = PagedAdapter(VLLM_GAUDI, IDN, "intel", "vllm-gaudi")
    ga = gaudi_caches(); ga_blocks = [6, 1, 4]

    rx = KVReceiver("tcp://127.0.0.1:0")
    endpoint = rx.sock.getsockopt_string(__import__("zmq").LAST_ENDPOINT)
    result = {}

    def serve():
        for _ in range(2):  # one good request, one corrupted
            hdr = rx.next_header()
            try:
                consumer.import_all(hdr, rx.frames(hdr), ga, ga_blocks)
                rx.ack(hdr)
                result[hdr.request_id] = "ok"
            except HandoffError as e:
                rx.drain(hdr)
                rx.ack(hdr, str(e))
                result[hdr.request_id] = "refused"

    t = threading.Thread(target=serve); t.start()
    tx = KVSender(endpoint)
    tx.begin(producer.make_header(range(seq), 5, "good"))
    for f in producer.export_all(nv, nv_blocks, seq):
        tx.send_layer(f)                      # layer-by-layer streaming
    tx.finish()
    assert tx.stats.last_gbps > 0

    tx.begin(producer.make_header(range(seq), 5, "bad"))
    frames = list(producer.export_all(nv, nv_blocks, seq))
    frames[1].k_crc ^= 1                       # corrupt one layer
    for f in frames:
        tx.send_layer(f)
    with pytest.raises(HandoffError, match="refused"):
        tx.finish()
    t.join(5); tx.close(); rx.close()

    assert result == {"good": "ok", "bad": "refused"}
    for (k, _), cache in zip(truth, ga):
        assert torch.equal(gather_layer(cache, VLLM_GAUDI, ga_blocks, seq)[0], k)


# ------------------------------------------------- HF offline (phase 2) ----
@pytest.fixture(scope="module")
def tiny_llama(tmp_path_factory):
    transformers = pytest.importorskip("transformers")
    d = tmp_path_factory.mktemp("tiny-llama")
    cfg = transformers.LlamaConfig(vocab_size=512, hidden_size=128, intermediate_size=256,
                                   num_hidden_layers=3, num_attention_heads=8,
                                   num_key_value_heads=2, max_position_embeddings=512)
    torch.manual_seed(0)
    model = transformers.LlamaForCausalLM(cfg).to(torch.bfloat16).eval()
    model.save_pretrained(d)
    return d, model


def test_hf_cross_engine_decode_matches_reference(tiny_llama, tmp_path):
    """Export on 'device A', import on 'device B' (both CPU here): decoded
    tokens must be identical to an uninterrupted local run."""
    from xvkv.hf_runner import export_prefill, import_and_decode, reference_decode

    model_dir, model = tiny_llama
    idn = identity_from_model_dir(model_dir)
    assert (idn.num_layers, idn.num_kv_heads, idn.head_dim) == (3, 2, 16)
    prod = HFCacheAdapter(idn, "nvidia", "hf")
    cons = HFCacheAdapter(idn, "intel", "hf")
    cpu = torch.device("cpu")
    results = []
    for i in range(5):
        prompt = torch.randint(0, 512, (40 + 13 * i,), generator=torch.Generator().manual_seed(i)).tolist()
        header, frames = export_prefill(model, prod, prompt, cpu, f"p{i}")
        write_handoff(tmp_path / f"p{i}.xvkv", header, frames)
        h2, f2 = read_handoff(tmp_path / f"p{i}.xvkv")
        cross = import_and_decode(model, cons, h2, f2, cpu, 24)
        ref = reference_decode(model, prompt, cpu, 24)
        r = compare(f"p{i}", ref.tokens, cross.tokens, prefix=24,
                    ref_logits=ref.first_step_logits, test_logits=cross.first_step_logits)
        results.append(r)
    assert all(r.first_divergence is None for r in results)
    assert all(r.kl_first_step < 1e-6 for r in results)


def test_identity_changes_with_rope(tiny_llama, tmp_path):
    model_dir, _ = tiny_llama
    a = identity_from_model_dir(model_dir)
    cfg = json.loads((model_dir / "config.json").read_text())
    cfg["rope_theta"] = 1234.0
    other = tmp_path / "m"; other.mkdir()
    for p in model_dir.iterdir():
        (other / p.name).write_bytes(p.read_bytes())
    (other / "config.json").write_text(json.dumps(cfg))
    b = identity_from_model_dir(other)
    assert a.rope_hash != b.rope_hash and a.model_hash != b.model_hash
