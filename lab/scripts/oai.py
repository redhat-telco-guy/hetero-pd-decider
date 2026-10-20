"""Minimal OpenAI-compatible streaming client with per-request timing.

Shared by profile_prefill.py, loadtest.py and correctness.py. Needs `requests`.
"""

from __future__ import annotations

import json
import random
import time
from dataclasses import dataclass, field

import requests

# Common English words; each is usually one Llama-3 token with its leading space.
_WORDS = (
    "the of and to in is that for it as was with be by on not he this are or his from at "
    "which but have an they you were her she there been one all we their has would when "
    "will more if no out so said what up its about into than them can only other new some "
    "could time these two may then do first any my now such like our over man me even most "
    "made after also did many before must through back years where much your way well down "
    "should because each just those people how too little state good very make world still "
    "own see men work long get here between both life being under never day same another "
    "know while last might us great old year off come since against go came right used take "
    "three states himself few house use during without again place american around however "
    "home small found thought went say part once general high upon school every though "
    "water power number give against city light form river table garden window mountain "
    "paper market engine signal kernel network memory cluster vendor router decode prefill"
).split()


def make_prompt(n_words: int, rng: random.Random) -> str:
    """Random word sequence. Unique per call, so prefix caches do not hit."""
    return " ".join(rng.choice(_WORDS) for _ in range(n_words))


@dataclass
class Result:
    ok: bool = False
    error: str = ""
    ttft_s: float = 0.0
    e2e_s: float = 0.0
    text: str = ""
    prompt_tokens: int = 0
    completion_tokens: int = 0
    chunk_times: list[float] = field(default_factory=list)

    @property
    def itls_s(self) -> list[float]:
        t = self.chunk_times
        return [b - a for a, b in zip(t, t[1:])]


def stream_completion(base_url: str, model: str, prompt: str, max_tokens: int,
                      temperature: float = 0.0, seed: int | None = None,
                      ignore_eos: bool = True, timeout: float = 300.0,
                      headers: dict | None = None) -> Result:
    body = {
        "model": model,
        "prompt": prompt,
        "max_tokens": max_tokens,
        "temperature": temperature,
        "stream": True,
        "stream_options": {"include_usage": True},
        "ignore_eos": ignore_eos,  # vLLM extension: fixed output length
    }
    if seed is not None:
        body["seed"] = seed
    res = Result()
    t0 = time.perf_counter()
    try:
        with requests.post(f"{base_url.rstrip('/')}/v1/completions", json=body,
                           stream=True, timeout=timeout, headers=headers or {}) as r:
            if r.status_code != 200:
                res.error = f"HTTP {r.status_code}: {r.text[:200]}"
                return res
            parts = []
            for raw in r.iter_lines(chunk_size=None, decode_unicode=True):
                if not raw or not raw.startswith("data:"):
                    continue
                data = raw[5:].strip()
                if data == "[DONE]":
                    break
                chunk = json.loads(data)
                if chunk.get("usage"):
                    res.prompt_tokens = chunk["usage"].get("prompt_tokens", 0)
                    res.completion_tokens = chunk["usage"].get("completion_tokens", 0)
                for choice in chunk.get("choices") or []:
                    text = choice.get("text") or ""
                    if text:
                        now = time.perf_counter()
                        if not res.chunk_times:
                            res.ttft_s = now - t0
                        res.chunk_times.append(now)
                        parts.append(text)
            res.text = "".join(parts)
            res.e2e_s = time.perf_counter() - t0
            res.ok = bool(res.chunk_times)
            if not res.ok:
                res.error = "no tokens received"
    except (requests.RequestException, ValueError) as e:
        res.error = f"{type(e).__name__}: {e}"
    return res


def percentile(values: list[float], p: float) -> float:
    if not values:
        return float("nan")
    s = sorted(values)
    k = (len(s) - 1) * p / 100.0
    lo, hi = int(k), min(int(k) + 1, len(s) - 1)
    return s[lo] + (s[hi] - s[lo]) * (k - lo)
