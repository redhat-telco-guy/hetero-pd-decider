#!/usr/bin/env python3
"""Measure the fixed cost of one remote-prefill handoff.

Sends the same kind of short prompt two ways to the decode pod, one at a time:
  local : straight to its vLLM engine (it reads the prompt itself)
  remote: to its routing sidecar with the prefill pod named in the header the
          router sets, so the prefill pod reads it and the KV is handed over
Overhead = median(remote TTFT) - median(local TTFT) - KV transfer time.
On A30-to-A30 both cards read at the same speed, so the difference is the handoff.
"""
import argparse, json, random, statistics, sys, time
import requests

WORDS = "the of and to in is that for it as was with be by on not this are or from at which have an they you".split()

def ttft(url, model, prompt, headers=None):
    t0 = time.perf_counter()
    with requests.post(url + "/v1/completions", json={"model": model, "prompt": prompt, "max_tokens": 1, "temperature": 0, "stream": True},
                       headers=headers or {}, stream=True, timeout=120) as r:
        r.raise_for_status()
        for line in r.iter_lines():
            if line and line.startswith(b"data:") and b"[DONE]" not in line:
                return time.perf_counter() - t0
    raise RuntimeError("no tokens")

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--engine", required=True, help="decode pod vLLM engine, e.g. http://localhost:18200")
    ap.add_argument("--sidecar", required=True, help="decode pod routing sidecar, e.g. http://localhost:18100")
    ap.add_argument("--prefill", required=True, help="prefill pod host:port as the router names it, e.g. 10.131.0.59:8000")
    ap.add_argument("--model", required=True)
    ap.add_argument("--tokens", type=int, default=300)
    ap.add_argument("--reps", type=int, default=20)
    ap.add_argument("--kv-bytes", type=int, default=57344)
    ap.add_argument("--gbps", type=float, default=10)
    a = ap.parse_args()
    rng = random.Random(3)
    mk = lambda: " ".join(rng.choice(WORDS) for _ in range(a.tokens))
    hdr = {"x-llm-d-prefiller-host-port": a.prefill, "x-prefiller-host-port": a.prefill}
    for _ in range(3):  # warm up both paths
        ttft(a.engine, a.model, mk()); ttft(a.sidecar, a.model, mk(), hdr)
    loc, rem = [], []
    for i in range(a.reps):
        loc.append(ttft(a.engine, a.model, mk()))
        rem.append(ttft(a.sidecar, a.model, mk(), hdr))
    l, r = statistics.median(loc), statistics.median(rem)
    transfer = a.tokens * a.kv_bytes / (a.gbps * 1e9 / 8)
    over = max(0.0, r - l - transfer)
    print(f"local TTFT  median {l*1000:7.1f} ms   (range {min(loc)*1000:.0f}-{max(loc)*1000:.0f})", file=sys.stderr)
    print(f"remote TTFT median {r*1000:7.1f} ms   (range {min(rem)*1000:.0f}-{max(rem)*1000:.0f})", file=sys.stderr)
    print(json.dumps({"localMs": round(l*1000, 1), "remoteMs": round(r*1000, 1), "transferMs": round(transfer*1000, 1), "handoffOverheadMs": round(over*1000)}))

if __name__ == "__main__":
    main()
