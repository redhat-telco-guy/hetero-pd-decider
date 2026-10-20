"""Host-staged KV transport over ZeroMQ, streamed layer by layer.

A30 and Gaudi 3 share no GPU-to-GPU RDMA path, so the lab baseline is:
    A30 HBM -> host RAM -> TCP (ZeroMQ) -> host RAM -> Gaudi HBM

Sockets: producer DEALER  ->  consumer ROUTER (consumer binds).
Messages for one request, in order:
    [b"HDR", header_json]
    [b"LYR", request_id, meta, k_bytes, v_bytes]     one per layer
    [b"END", request_id]
Consumer replies [b"ACK", request_id, b"ok" | b"err:<reason>"] so the
producer knows when it may free its prefill blocks.

Measured bytes/second per handoff is kept in `stats`, which the Kubernetes
scorer uses to estimate T_transfer for the next request.
"""

from __future__ import annotations

import time
from dataclasses import dataclass, field
from typing import Iterator, Optional

import zmq

from .wire import HandoffError, KVHeader, LayerFrame, dtype_from_name


@dataclass
class TransferStats:
    requests: int = 0
    bytes_sent: int = 0
    seconds: float = 0.0
    last_gbps: float = 0.0
    history: list = field(default_factory=list)

    def record(self, nbytes: int, secs: float) -> None:
        self.requests += 1
        self.bytes_sent += nbytes
        self.seconds += secs
        self.last_gbps = (nbytes * 8 / secs / 1e9) if secs > 0 else 0.0
        self.history = (self.history + [self.last_gbps])[-50:]

    @property
    def avg_gbps(self) -> float:
        return self.bytes_sent * 8 / self.seconds / 1e9 if self.seconds else 0.0


class KVSender:
    """Producer side (A30). One sender can carry many requests sequentially."""

    def __init__(self, endpoint: str, ctx: Optional[zmq.Context] = None,
                 ack_timeout_ms: int = 30_000):
        self.ctx = ctx or zmq.Context.instance()
        self.sock = self.ctx.socket(zmq.DEALER)
        self.sock.setsockopt(zmq.LINGER, 0)
        self.sock.connect(endpoint)
        self.ack_timeout_ms = ack_timeout_ms
        self.stats = TransferStats()
        self._t0 = 0.0
        self._bytes = 0
        self._rid: Optional[bytes] = None

    def begin(self, header: KVHeader) -> None:
        self._rid = header.request_id.encode()
        self._t0 = time.perf_counter()
        hdr = header.to_bytes()
        self._bytes = len(hdr)
        self.sock.send_multipart([b"HDR", hdr])

    def send_layer(self, frame: LayerFrame) -> None:
        """Call as soon as prefill finishes a layer (overlaps with compute)."""
        if self._rid is None:
            raise HandoffError("send_layer before begin")
        parts = frame.to_parts()
        self._bytes += sum(len(p) for p in parts)
        self.sock.send_multipart([b"LYR", self._rid, *parts], copy=False)

    def finish(self) -> None:
        """Send END and wait for the consumer's verdict. Raises on refusal."""
        rid = self._rid
        self.sock.send_multipart([b"END", rid])
        if not self.sock.poll(self.ack_timeout_ms):
            raise HandoffError(f"no ACK for {rid.decode()} "
                               f"within {self.ack_timeout_ms} ms")
        kind, ack_rid, status = self.sock.recv_multipart()
        self.stats.record(self._bytes, time.perf_counter() - self._t0)
        self._rid = None
        if kind != b"ACK" or ack_rid != rid:
            raise HandoffError(f"unexpected reply {kind!r} for {ack_rid!r}")
        if status != b"ok":
            raise HandoffError(f"consumer refused {rid.decode()}: {status.decode()}")

    def close(self) -> None:
        self.sock.close()


class KVReceiver:
    """Consumer side (Gaudi 3). Binds, then hands out one request at a time."""

    def __init__(self, bind: str, ctx: Optional[zmq.Context] = None,
                 recv_timeout_ms: int = 30_000):
        self.ctx = ctx or zmq.Context.instance()
        self.sock = self.ctx.socket(zmq.ROUTER)
        self.sock.setsockopt(zmq.LINGER, 0)
        self.sock.bind(bind)
        self.timeout = recv_timeout_ms
        self._peer: Optional[bytes] = None

    def _recv(self) -> list[bytes]:
        if not self.sock.poll(self.timeout):
            raise HandoffError("timed out waiting for producer")
        peer, *msg = self.sock.recv_multipart()
        if self._peer is not None and peer != self._peer:
            raise HandoffError("interleaved producers are not supported yet")
        self._peer = peer
        return msg

    def next_header(self) -> KVHeader:
        self._peer = None
        msg = self._recv()
        if msg[0] != b"HDR":
            raise HandoffError(f"expected HDR, got {msg[0]!r}")
        return KVHeader.from_bytes(msg[1])

    def frames(self, header: KVHeader) -> Iterator[LayerFrame]:
        """Yield layer frames as they arrive, until END."""
        rid = header.request_id.encode()
        dtype = dtype_from_name(header.identity.dtype)
        while True:
            msg = self._recv()
            if msg[0] == b"END":
                if msg[1] != rid:
                    raise HandoffError("END for another request")
                return
            if msg[0] != b"LYR" or msg[1] != rid:
                raise HandoffError(f"unexpected message {msg[0]!r}")
            yield LayerFrame.from_parts(msg[2:], dtype)

    def drain(self, header: KVHeader) -> None:
        """After a refused import, discard the rest of that request's messages
        so the next header is read cleanly."""
        rid = header.request_id.encode()
        while True:
            msg = self._recv()
            if msg[0] == b"END" and msg[1] == rid:
                return

    def ack(self, header: KVHeader, error: Optional[str] = None) -> None:
        status = b"ok" if error is None else f"err:{error}".encode()
        self.sock.send_multipart([self._peer, b"ACK",
                                  header.request_id.encode(), status])

    def close(self) -> None:
        self.sock.close()
