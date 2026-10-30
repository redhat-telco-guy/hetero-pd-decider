#!/usr/bin/env python3
"""Correctness with a noise baseline.

For each prompt, three greedy 64-token outputs:
  R = through the router (prefill on one card, KV transferred, decode on another)
  D = decode pod alone (prefill + decode locally)
  P = prefill pod alone (prefill + decode locally)
P vs D is the baseline: two cards that never exchange KV. If R agrees with D
(and with P) about as often as P agrees with D, the KV transfer adds no error.
Prompts are realistic text (generated incident reports and runbooks + a
question), unique per prompt so no prefix cache is shared across prompts.
The router request is always sent first.
"""
from __future__ import annotations
import argparse, random, statistics, sys
from oai import stream_completion

SERVICES = ["checkout-api", "payments-gateway", "inventory-sync", "auth-proxy", "search-indexer",
            "billing-worker", "order-router", "image-resizer", "notification-hub", "ledger-db"]
REGIONS = ["us-east", "us-west", "eu-central", "ap-south", "sa-east"]
CAUSES = ["a certificate that expired at midnight", "a connection pool capped at 50", "a config push with a typo in the port",
          "disk usage reaching 100% on the log volume", "a DNS record that pointed at a retired load balancer",
          "a memory leak in the JSON parser", "a schema migration that locked the orders table",
          "a retry storm after a 2-second network blip", "clock skew of 40 seconds on two nodes",
          "a rate limit of 1,000 requests per minute set by the upstream vendor"]
ACTIONS = ["rolled back the deployment", "raised the pool size to 200", "rotated the certificate",
           "added an alert on disk usage at 80%", "pinned the DNS TTL to 60 seconds",
           "patched the parser and redeployed", "moved the migration to a maintenance window",
           "added jitter to the retry backoff", "enabled NTP on every node", "requested a higher vendor quota"]
QUESTIONS = ["Which service failed first, and what was the root cause?",
             "Summarize the incident in two sentences for an executive.",
             "List the follow-up actions the team should take next week.",
             "What alert would have caught this problem earlier? Explain briefly.",
             "Write a short timeline of the incident with times."]

def make_text_prompt(rng: random.Random, n_paragraphs: int) -> str:
    paras = []
    hour = rng.randint(0, 20)
    for k in range(n_paragraphs):
        s, s2 = rng.sample(SERVICES, 2)
        r = rng.choice(REGIONS); c = rng.choice(CAUSES); a = rng.choice(ACTIONS)
        m = rng.randint(1, 59); pct = rng.randint(3, 97); n = rng.randint(2, 40)
        paras.append(
            f"At {hour + k // 3:02d}:{m:02d} UTC the on-call engineer saw error rates on {s} in {r} rise to {pct}% "
            f"of requests. Requests from {s2} began timing out after {n} seconds. The investigation found {c}. "
            f"The team {a}, and error rates returned to normal within {rng.randint(3, 50)} minutes. "
            f"Customers in {r} saw failed requests during that window, and {rng.randint(10, 9000)} support tickets were opened."
        )
    q = rng.choice(QUESTIONS)
    return ("You are a site reliability engineer. Read the incident notes and answer the question.\n\n"
            "Incident notes:\n" + "\n\n".join(paras) + f"\n\nQuestion: {q}\nAnswer:")

def first_div(a: str, b: str):
    for i, (x, y) in enumerate(zip(a, b)):
        if x != y:
            return i
    return None if len(a) == len(b) else min(len(a), len(b))

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--router", required=True)
    ap.add_argument("--decode", required=True)
    ap.add_argument("--prefill", required=True)
    ap.add_argument("--model", required=True)
    ap.add_argument("--prompts", type=int, default=150)
    ap.add_argument("--max-tokens", type=int, default=64)
    ap.add_argument("--seed", type=int, default=23)
    a = ap.parse_args()
    rng = random.Random(a.seed)
    agree = {"R=D": 0, "R=P": 0, "P=D": 0}
    divs = {"R=D": [], "P=D": []}
    n = fails = 0
    for i in range(a.prompts):
        prompt = make_text_prompt(rng, rng.randint(4, 14))
        R = stream_completion(a.router, a.model, prompt, a.max_tokens, seed=0, ignore_eos=False)
        D = stream_completion(a.decode, a.model, prompt, a.max_tokens, seed=0, ignore_eos=False)
        P = stream_completion(a.prefill, a.model, prompt, a.max_tokens, seed=0, ignore_eos=False)
        if not (R.ok and D.ok and P.ok):
            fails += 1
            print(f"[{i}] failed: R={R.error!r} D={D.error!r} P={P.error!r}", file=sys.stderr)
            continue
        n += 1
        for key, x, y in (("R=D", R, D), ("R=P", R, P), ("P=D", P, D)):
            d = first_div(x.text, y.text)
            if d is None:
                agree[key] += 1
            elif key in divs:
                divs[key].append(d)
        if first_div(R.text, D.text) is not None:
            d = first_div(R.text, D.text)
            print(f"[{i}] R vs D differ at char {d}: R={R.text[max(0,d-25):d+25]!r} D={D.text[max(0,d-25):d+25]!r}", file=sys.stderr)
        if i % 25 == 0:
            print(f"[{i}] prompt_tokens={R.prompt_tokens} sample answer: {R.text[:90]!r}", file=sys.stderr)
    if not n:
        print("no prompts compared"); sys.exit(1)
    rd, rp, pd = (agree[k] / n for k in ("R=D", "R=P", "P=D"))
    print(f"compared {n} prompts (failed {fails})")
    print(f"router vs decode-alone  identical: {agree['R=D']}/{n} = {rd:.1%}")
    print(f"router vs prefill-alone identical: {agree['R=P']}/{n} = {rp:.1%}")
    print(f"BASELINE prefill-alone vs decode-alone (no KV transfer): {agree['P=D']}/{n} = {pd:.1%}")
    if divs["R=D"]:
        print(f"router vs decode: median first difference at char {statistics.median(divs['R=D']):.0f}")
    if divs["P=D"]:
        print(f"baseline:          median first difference at char {statistics.median(divs['P=D']):.0f}")
    ok = rd >= 0.95 or rd >= pd - 0.03
    print("VERDICT: transfer adds no measurable error" if ok else "VERDICT: router path disagrees more than the card-to-card baseline: investigate the KV transfer")
    sys.exit(0 if ok else 1)

if __name__ == "__main__":
    main()
