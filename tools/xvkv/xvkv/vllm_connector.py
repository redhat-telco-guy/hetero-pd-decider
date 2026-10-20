"""PHASE 3 SKELETON — xvkv as a vLLM v1 KV Connector.

STATUS: design skeleton, not yet runnable. It shows exactly where xvkv plugs
into vLLM's KV Connector API (the same hook NixlConnector and AMD's MORI-IO
connector use). The method names follow vLLM's KVConnectorBase_V1; argument
lists drift between releases, so pin ONE vLLM version on the A30 and on the
Gaudi plugin, open vllm/distributed/kv_transfer/kv_connector/v1/base.py for
that version, and adjust signatures before wiring the TODOs.

Roles
-----
A30 (kv_role="kv_producer"):   save_kv_layer() gathers each layer as soon as
                                its forward pass finishes and streams it.
Gaudi (kv_role="kv_consumer"): get_num_new_matched_tokens() tells the
                                scheduler the prompt is already computed;
                                start_load_kv() scatters the received layers
                                into the blocks the scheduler allocated.

Enable with (example):
  --kv-transfer-config '{"kv_connector":"XVKVConnector",
     "kv_connector_module_path":"xvkv.vllm_connector",
     "kv_role":"kv_producer",
     "kv_connector_extra_config":{"endpoint":"tcp://gaudi-0:5557",
        "layout":{"name":"probed","block_size":16,"axes":"KNBHD"},
        "model_dir":"/models/Llama-3.1-8B-Instruct"}}'
"""

from __future__ import annotations

import queue
import threading
from dataclasses import dataclass, field
from typing import Any, Optional

from .adapters import PagedAdapter, default_sync_for
from .identity import identity_from_model_dir
from .layout import LayoutSpec, blocks_needed
from .transport import KVReceiver, KVSender
from .wire import HandoffError, KVHeader

try:  # only importable inside a vLLM install
    from vllm.distributed.kv_transfer.kv_connector.v1.base import (  # type: ignore
        KVConnectorBase_V1, KVConnectorMetadata, KVConnectorRole)
except ImportError:  # keeps the module importable for tests and docs
    KVConnectorBase_V1 = object  # type: ignore

    class KVConnectorMetadata:  # type: ignore
        pass

    class KVConnectorRole:  # type: ignore
        SCHEDULER = "scheduler"
        WORKER = "worker"


@dataclass
class _ReqPlan:
    request_id: str
    token_ids: list[int]
    block_ids: list[int]
    load: bool                       # consumer: load KV for this request
    save: bool                       # producer: stream KV for this request


@dataclass
class XVKVMetadata(KVConnectorMetadata):
    """Built by the scheduler each step, read by the worker the same step."""
    plans: list[_ReqPlan] = field(default_factory=list)


class XVKVConnector(KVConnectorBase_V1):  # type: ignore[misc]
    def __init__(self, vllm_config: Any, role: Any, *args, **kwargs):
        if KVConnectorBase_V1 is not object:
            super().__init__(vllm_config, role, *args, **kwargs)
        kv_cfg = vllm_config.kv_transfer_config
        extra = kv_cfg.kv_connector_extra_config or {}
        self.role = role
        self.is_producer = kv_cfg.kv_role == "kv_producer"
        self.spec = LayoutSpec(**extra["layout"])
        self.identity = identity_from_model_dir(extra["model_dir"])
        self.endpoint = extra.get("endpoint")             # producer connects here
        self.bind = extra.get("bind", "tcp://0.0.0.0:5557")  # consumer binds here
        self.adapter: Optional[PagedAdapter] = None
        self.kv_caches: dict[str, Any] = {}
        self.layer_names: list[str] = []
        # consumer: request_id -> (header, frames) received by the listener
        self._ready: dict[str, tuple[KVHeader, list]] = {}
        self._lock = threading.Lock()
        self._sender: Optional[KVSender] = None
        self._send_q: "queue.Queue" = queue.Queue()

    # ================= scheduler side =======================================
    def get_num_new_matched_tokens(self, request, num_computed_tokens: int):
        """Consumer: if this request's KV arrived from the A30, report all
        prompt tokens as externally computed so the scheduler skips prefill.
        Returns (num_tokens, load_async)."""
        if self.is_producer:
            return 0, False
        with self._lock:
            got = self._ready.get(request.request_id)
        if got is None:
            return 0, False
        header, _ = got
        # TODO(version): vLLM may require leaving the last prompt token
        # uncomputed so it produces logits; if so return header.seq_len - 1 and
        # inject header.first_output_token instead of recomputing it.
        return header.seq_len - num_computed_tokens, False

    def update_state_after_alloc(self, request, blocks, num_external_tokens: int):
        """Consumer: the scheduler just allocated Gaudi blocks for the prompt.
        Record their ids so the worker can scatter into them."""
        if num_external_tokens == 0:
            return
        need = blocks_needed(num_external_tokens, self.spec)
        block_ids = blocks.get_block_ids()[0][:need]  # TODO(version): API shape
        self._pending_load = getattr(self, "_pending_load", [])
        self._pending_load.append(_ReqPlan(request.request_id,
                                           list(request.prompt_token_ids),
                                           list(block_ids), load=True, save=False))

    def build_connector_meta(self, scheduler_output) -> XVKVMetadata:
        meta = XVKVMetadata()
        meta.plans.extend(getattr(self, "_pending_load", []))
        self._pending_load = []
        if self.is_producer:
            # TODO(version): walk scheduler_output.scheduled_new_reqs and add a
            # save plan (request_id, prompt_token_ids, block_ids) for every
            # request routed here for remote decode (kv_transfer_params from
            # the router mark which ones).
            pass
        return meta

    def request_finished(self, request, block_ids):
        """Producer: keep blocks alive until the consumer ACKs, then free.
        Returns (delay_free, kv_transfer_params for the router)."""
        if not self.is_producer:
            return False, None
        return True, {"xvkv_endpoint": self.endpoint}

    # ================= worker side ==========================================
    def register_kv_caches(self, kv_caches: dict[str, Any]):
        """Called once with {layer_name: cache_tensor}. Layer order = model order."""
        self.kv_caches = kv_caches
        self.layer_names = list(kv_caches)
        first = next(iter(kv_caches.values()))
        device = (first[0] if isinstance(first, (tuple, list)) else first).device
        self.adapter = PagedAdapter(self.spec, self.identity,
                                    "nvidia" if self.is_producer else "intel",
                                    "vllm", sync=default_sync_for(device))
        if self.is_producer:
            self._sender = KVSender(self.endpoint)
        else:
            threading.Thread(target=self._listen, daemon=True).start()

    def _listen(self):
        """Consumer background thread: receive whole handoffs into host memory."""
        rx = KVReceiver(self.bind)
        while True:
            header = rx.next_header()
            try:
                frames = list(rx.frames(header))
                for f in frames:
                    f.verify(header)
                with self._lock:
                    self._ready[header.request_id] = (header, frames)
                rx.ack(header)
            except HandoffError as e:
                rx.drain(header)
                rx.ack(header, str(e))

    def start_load_kv(self, forward_context, **kwargs):
        """Consumer: scatter every planned request into its Gaudi blocks."""
        meta: XVKVMetadata = self._get_connector_metadata()  # base-class helper
        caches = [self.kv_caches[n] for n in self.layer_names]
        for plan in meta.plans:
            if not plan.load:
                continue
            with self._lock:
                header, frames = self._ready.pop(plan.request_id)
            self.adapter.import_all(header, frames, caches, plan.block_ids)

    def wait_for_layer_load(self, layer_name: str):
        return  # loads complete synchronously in start_load_kv for now

    def save_kv_layer(self, layer_name: str, kv_layer, attn_metadata, **kwargs):
        """Producer: called after each layer's attention. Gather this layer for
        every request being sent and stream it, overlapping with later layers."""
        if not self.is_producer:
            return
        meta: XVKVMetadata = self._get_connector_metadata()
        idx = self.layer_names.index(layer_name)
        for plan in meta.plans:
            if not plan.save:
                continue
            if idx == 0:
                # TODO: first_output_token is not known until sampling; send it
                # in a trailer message after the forward pass instead.
                self._sender.begin(self.adapter.make_header(plan.token_ids, -1,
                                                            plan.request_id))
            self._sender.send_layer(self.adapter.export_layer(
                idx, kv_layer, plan.block_ids, len(plan.token_ids)))

    def wait_for_save(self):
        """Producer: end of forward pass — close every handoff and await ACKs."""
        if not self.is_producer:
            return
        meta: XVKVMetadata = self._get_connector_metadata()
        for plan in meta.plans:
            if plan.save:
                self._sender.finish()

    def get_finished(self, finished_req_ids):
        return None, None
