#!/usr/bin/env python3
"""Mixed workload against the router, recording TTFT and inter-token latency.

Three request classes run together:
  chat   N concurrent users looping short prompts with long outputs (keeps decode busy)
  long   Poisson arrivals of long prompts with short outputs
  burst  B long prompts sent at once at a fixed time

  oc port-forward svc/hetero-pd-epp 8081:80 &     # or the router route
  python loadtest.py --url http://localhost:8081 --model meta-llama/Llama-3.1-8B-Instruct \
      --out run-hetero.csv

Run the same command (same --seed) under each router config, then compare.py.
"""

from __future__ import annotations

import argparse
import csv
import random
import statistics
import threading
import time

from oai import make_prompt, percentile, stream_completion

FIELDS = ["start_s", "cls", "prompt_tokens", "completion_tokens", "ttft_ms",
          "itl_mean_ms", "itl_p95_ms", "e2e_ms", "error"]


class Recorder:
    def __init__(self) -> None:
        self.rows: list[dict] = []
        self.lock = threading.Lock()
        self.t0 = time.perf_counter()

    def run(self, cls: str, args, prompt_words: int, max_tokens: int, rng: random.Random) -> None:
        start = time.perf_counter() - self.t0
        r = stream_completion(args.url, args.model, make_prompt(prompt_words, rng), max_tokens)
        itls = [x * 1000 for x in r.itls_s]
        row = {
            "start_s": round(start, 3), "cls": cls,
            "prompt_tokens": r.prompt_tokens, "completion_tokens": r.completion_tokens,
            "ttft_ms": round(r.ttft_s * 1000, 1) if r.ok else "",
            "itl_mean_ms": round(statistics.fmean(itls), 2) if itls else "",
            "itl_p95_ms": round(percentile(itls, 95), 2) if itls else "",
            "e2e_ms": round(r.e2e_s * 1000, 1) if r.ok else "",
            "error": r.error,
        }
        with self.lock:
            self.rows.append(row)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", required=True)
    ap.add_argument("--model", required=True)
    ap.add_argument("--duration", type=float, default=300, help="seconds")
    ap.add_argument("--chat-users", type=int, default=32)
    ap.add_argument("--chat-prompt", type=int, default=200, help="words")
    ap.add_argument("--chat-output", type=int, default=256, help="tokens")
    ap.add_argument("--long-rate", type=float, default=0.5, help="long prompts per second")
    ap.add_argument("--long-prompt", type=int, default=2000, help="words")
    ap.add_argument("--long-output", type=int, default=64, help="tokens")
    ap.add_argument("--burst-at", type=float, default=150, help="seconds; negative disables")
    ap.add_argument("--burst-size", type=int, default=10)
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    rec = Recorder()
    stop = threading.Event()
    threads: list[threading.Thread] = []

    def chat_user(i: int) -> None:
        rng = random.Random(args.seed * 1000 + i)
        time.sleep(rng.uniform(0, 5))
        while not stop.is_set():
            rec.run("chat", args, args.chat_prompt, args.chat_output, rng)

    for i in range(args.chat_users):
        t = threading.Thread(target=chat_user, args=(i,), daemon=True)
        t.start()
        threads.append(t)

    arrival_rng = random.Random(args.seed)
    burst_done = args.burst_at < 0
    next_long = arrival_rng.expovariate(args.long_rate) if args.long_rate > 0 else float("inf")
    n = 0
    while (now := time.perf_counter() - rec.t0) < args.duration:
        if now >= next_long:
            n += 1
            t = threading.Thread(target=rec.run, daemon=True,
                                 args=("long", args, args.long_prompt, args.long_output,
                                       random.Random(args.seed * 7919 + n)))
            t.start()
            threads.append(t)
            next_long += arrival_rng.expovariate(args.long_rate)
        if not burst_done and now >= args.burst_at:
            burst_done = True
            for b in range(args.burst_size):
                t = threading.Thread(target=rec.run, daemon=True,
                                     args=("burst", args, args.long_prompt, args.long_output,
                                           random.Random(args.seed * 104729 + b)))
                t.start()
                threads.append(t)
        time.sleep(0.01)

    stop.set()
    for t in threads:
        t.join(timeout=300)

    with open(args.out, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=FIELDS)
        w.writeheader()
        w.writerows(sorted(rec.rows, key=lambda r: r["start_s"]))
    print(f"wrote {len(rec.rows)} requests to {args.out}")


if __name__ == "__main__":
    main()
