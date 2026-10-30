#!/usr/bin/env python3
"""Cold-cache correctness: separates the KV transfer from prefix-cache effects.

Every call gets its own vLLM `cache_salt`, so no call reuses another's cached KV,
except the one deliberately warm call. Per prompt (greedy, up to 64 tokens):
  R      router (prefill on one card, KV over NIXL, decode on the other), cold
  Dcold  decode pod alone, cold
  Pcold  prefill pod alone, cold
  Dwarm  decode pod alone, reusing Dcold's cached prompt KV (same salt)
Reads:
  Pcold = Dcold : card-to-card baseline
  R     = Dcold : the KV transfer, with no caching involved
  Dwarm = Dcold : what reusing cached KV alone does to the output
"""
from __future__ import annotations
import argparse, random, sys, uuid
import requests
from correctness2 import make_text_prompt, first_div

def complete(base, model, prompt, salt, max_tokens):
    body = {"model": model, "prompt": prompt, "max_tokens": max_tokens, "temperature": 0, "seed": 0, "cache_salt": salt}
    r = requests.post(base.rstrip("/") + "/v1/completions", json=body, timeout=300)
    if r.status_code != 200:
        raise RuntimeError(f"HTTP {r.status_code}: {r.text[:160]}")
    return r.json()["choices"][0]["text"]

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--router", required=True); ap.add_argument("--decode", required=True)
    ap.add_argument("--prefill", required=True); ap.add_argument("--model", required=True)
    ap.add_argument("--prompts", type=int, default=100); ap.add_argument("--max-tokens", type=int, default=64)
    ap.add_argument("--seed", type=int, default=29)
    a = ap.parse_args()
    rng = random.Random(a.seed)
    pairs = {"Pcold=Dcold": 0, "R=Dcold": 0, "R=Pcold": 0, "Dwarm=Dcold": 0}
    n = fails = 0
    for i in range(a.prompts):
        p = make_text_prompt(rng, rng.randint(4, 14))
        s = lambda: uuid.uuid4().hex
        try:
            R = complete(a.router, a.model, p, s(), a.max_tokens)
            dsalt = s()
            Dc = complete(a.decode, a.model, p, dsalt, a.max_tokens)
            Pc = complete(a.prefill, a.model, p, s(), a.max_tokens)
            Dw = complete(a.decode, a.model, p, dsalt, a.max_tokens)
        except Exception as ex:
            fails += 1; print(f"[{i}] failed: {ex}", file=sys.stderr); continue
        n += 1
        res = {"Pcold=Dcold": (Pc, Dc), "R=Dcold": (R, Dc), "R=Pcold": (R, Pc), "Dwarm=Dcold": (Dw, Dc)}
        for k, (x, y) in res.items():
            if first_div(x, y) is None: pairs[k] += 1
        d = first_div(R, Dc)
        if d is not None:
            print(f"[{i}] R vs Dcold differ at char {d}: R={R[max(0,d-25):d+25]!r} D={Dc[max(0,d-25):d+25]!r}", file=sys.stderr)
    if not n:
        print("no prompts compared"); sys.exit(1)
    print(f"compared {n} prompts (failed {fails}); every call has its own cache_salt")
    for k, label in (("Pcold=Dcold", "BASELINE  two cards, both cold          "),
                     ("R=Dcold",     "TRANSFER  router (KV over NIXL) vs cold  "),
                     ("R=Pcold",     "          router vs prefill card cold    "),
                     ("Dwarm=Dcold", "CACHE     same card, cached KV vs cold   ")):
        print(f"{label}: {pairs[k]}/{n} = {pairs[k]/n:.1%}")
    base, xfer, cache = pairs["Pcold=Dcold"]/n, pairs["R=Dcold"]/n, pairs["Dwarm=Dcold"]/n
    if xfer >= base - 0.03:
        print("VERDICT: KV transfer is clean: the router path matches cold local compute as well as two cards match each other.")
    elif abs(xfer - cache) <= 0.08:
        print("VERDICT: the router path differs about as much as reusing cached KV does. This is the normal cached-KV effect of disaggregation, not a transfer fault.")
    else:
        print("VERDICT: the router path differs more than both the baseline and the cache effect: investigate the KV transfer.")

if __name__ == "__main__":
    main()
