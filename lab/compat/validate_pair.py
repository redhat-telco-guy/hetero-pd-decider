#!/usr/bin/env python3
"""Validate that a prefill pod can hand KV to a decode pod correctly, before allowing it.

Runs inside the cluster (as a Job), so no port-forwards are involved. For each prompt,
every call uses its own vLLM cache_salt, so no call reuses cached KV from another:

  D   decode pod alone (its own prefill)            the reference
  P   prefill pod alone                             card-to-card baseline
  S   split: prefill pod -> NIXL KV -> decode pod   the handoff under test
      (sent to the decode pod's routing sidecar with the prefill host header,
       exactly as the router does)

All calls are greedy (temperature 0) and return per-token log-probabilities.

The handoff passes when:
  1. every split request succeeds (a rejected handshake shows up as errors here),
  2. the first answer token of S equals D's in at least 95% of prompts, and
  3. S agrees with D for at least as long as P does, minus a 10% allowance.

Why compare against P: two different cards rarely produce bit-identical numbers, so even
a perfect handoff can drift from D after a while. A broken layout (the silent-garbage
case) disagrees from the first token. Condition 3 asks that the handoff be no worse than
running the whole request on the other card.

This checks the handoff end to end (tokens and log-probabilities), not the raw KV bytes.

It stores the full result in the ConfigMap kv-compat-results under "<prefillKey>.to.<decodeKey>",
where the kv-compat labeler picks it up and shows the pair as waiting for approval (PASS) or
failed. Approval is a separate, human step: the dashboard's Card compatibility panel, or
62-approve-pair.sh.
"""
import json, os, random, ssl, statistics, sys, time, urllib.error, urllib.parse, urllib.request, uuid

NS = open("/var/run/secrets/kubernetes.io/serviceaccount/namespace").read().strip()
API = "https://kubernetes.default.svc"
CTX = ssl.create_default_context(cafile="/var/run/secrets/kubernetes.io/serviceaccount/ca.crt")
KEY_LABEL = os.environ.get("KEY_LABEL", "llm-d.ai/kv-compat-key")
WORDS = ("incident region service latency outage customer request timeout database cache deploy rollback "
         "certificate network gateway payments search ledger queue retry alert threshold capacity disk memory "
         "cpu error rate root cause mitigation followup owner timeline impact summary engineer").split()


def tok():
    return open("/var/run/secrets/kubernetes.io/serviceaccount/token").read().strip()


def k8s(method, path, body=None, ctype="application/json"):
    req = urllib.request.Request(API + path, method=method, data=json.dumps(body).encode() if body is not None else None)
    req.add_header("Authorization", "Bearer " + tok())
    if body is not None:
        req.add_header("Content-Type", ctype)
    with urllib.request.urlopen(req, timeout=15, context=CTX) as r:
        return json.loads(r.read())


def pod_of(name):
    """A running pod by pod name or by deployment name prefix."""
    pods = k8s("GET", f"/api/v1/namespaces/{NS}/pods")["items"]
    for p in pods:
        n = p["metadata"]["name"]
        if p["status"].get("phase") == "Running" and (n == name or n.startswith(name + "-")):
            return p
    raise SystemExit(f"no running pod for {name!r}")


def port_of(pod, port_name, container_names=None):
    for c in pod["spec"].get("initContainers", []) + pod["spec"]["containers"]:
        if container_names and c["name"] not in container_names:
            continue
        for p in c.get("ports", []):
            if p.get("name") == port_name:
                return p["containerPort"]
    return None


def complete(host_port, model, prompt, max_tokens, headers=None):
    body = {"model": model, "prompt": prompt, "max_tokens": max_tokens, "temperature": 0, "seed": 0,
            "logprobs": 1, "cache_salt": uuid.uuid4().hex}
    req = urllib.request.Request(f"http://{host_port}/v1/completions", data=json.dumps(body).encode(), method="POST")
    req.add_header("Content-Type", "application/json")
    for k, v in (headers or {}).items():
        req.add_header(k, v)
    try:
        with urllib.request.urlopen(req, timeout=300) as r:
            j = json.loads(r.read())
    except urllib.error.HTTPError as e:
        raise RuntimeError(f"HTTP {e.code}: {e.read()[:160]!r}")
    lp = j["choices"][0].get("logprobs") or {}
    return lp.get("tokens") or [], lp.get("token_logprobs") or []


def agree(a, b):
    n = 0
    for x, y in zip(a, b):
        if x != y:
            break
        n += 1
    return n


def make_prompt(rng, words):
    return ("Summarise the following incident notes for an engineering review.\n\n"
            + " ".join(rng.choice(WORDS) for _ in range(words)) + "\n\nSummary:")


def main():
    model = os.environ["MODEL"]
    prefill_pod, decode_pod = pod_of(os.environ["PREFILL"]), pod_of(os.environ["DECODE"])
    n = int(os.environ.get("PROMPTS", "30"))
    max_tokens = int(os.environ.get("MAX_TOKENS", "32"))
    rng = random.Random(int(os.environ.get("SEED", "7")))

    p_ip, d_ip = prefill_pod["status"]["podIP"], decode_pod["status"]["podIP"]
    p_port = port_of(prefill_pod, "modelserver") or 8000
    d_vllm = port_of(decode_pod, "modelserver") or 8200
    d_sidecar = port_of(decode_pod, "sidecar") or 8000
    p_key = prefill_pod["metadata"].get("labels", {}).get(KEY_LABEL, "")
    d_key = decode_pod["metadata"].get("labels", {}).get(KEY_LABEL, "")
    hp = f"{p_ip}:{p_port}"
    split_headers = {"x-llm-d-prefiller-host-port": hp, "x-prefiller-host-port": hp}

    print(f"prefill {prefill_pod['metadata']['name']} {hp} key={p_key or '-'}")
    print(f"decode  {decode_pod['metadata']['name']} vLLM {d_ip}:{d_vllm} sidecar {d_ip}:{d_sidecar} key={d_key or '-'}")
    print(f"{n} prompts, greedy, {max_tokens} tokens each, fresh cache per call\n")

    rows, errors = [], 0
    for i in range(n):
        prompt = make_prompt(rng, rng.randint(250, 2200))
        try:
            d_tok, d_lp = complete(f"{d_ip}:{d_vllm}", model, prompt, max_tokens)
            p_tok, _ = complete(hp, model, prompt, max_tokens)
        except Exception as ex:
            print(f"[{i}] reference call failed: {ex}")
            continue
        t0 = time.time()
        try:
            s_tok, s_lp = complete(f"{d_ip}:{d_sidecar}", model, prompt, max_tokens, split_headers)
        except Exception as ex:
            errors += 1
            print(f"[{i}] SPLIT FAILED: {ex}")
            continue
        row = {"first_match": bool(s_tok and d_tok and s_tok[0] == d_tok[0]),
               "s_vs_d": agree(s_tok, d_tok), "p_vs_d": agree(p_tok, d_tok),
               "first_lp_delta": abs(s_lp[0] - d_lp[0]) if s_lp and d_lp and s_lp[0] is not None and d_lp[0] is not None else None,
               "split_seconds": round(time.time() - t0, 3)}
        rows.append(row)
        print(f"[{i}] first token {'same' if row['first_match'] else 'DIFFERENT'}; agrees with decode-alone for "
              f"{row['s_vs_d']}/{max_tokens} tokens (prefill card alone: {row['p_vs_d']}/{max_tokens})")

    done = len(rows)
    first = sum(r["first_match"] for r in rows) / done if done else 0
    s_mean = statistics.mean(r["s_vs_d"] for r in rows) if done else 0
    p_mean = statistics.mean(r["p_vs_d"] for r in rows) if done else 0
    deltas = [r["first_lp_delta"] for r in rows if r["first_lp_delta"] is not None]
    checks = {
        "no split failures": errors == 0 and done > 0,
        "first token matches in >= 95% of prompts": first >= 0.95,
        "split agrees at least as long as the prefill card alone (-10%)": s_mean >= 0.9 * p_mean,
    }
    passed = all(checks.values())
    print(f"\nsplit failures: {errors}   compared: {done}")
    print(f"first token same: {first:.0%}   mean agreement: split {s_mean:.1f} vs prefill-card-alone {p_mean:.1f} tokens")
    if deltas:
        print(f"first-token log-prob difference: median {statistics.median(deltas):.4f}, max {max(deltas):.4f}")
    for k, v in checks.items():
        print(f"  {'PASS' if v else 'FAIL'}  {k}")
    pair = f"{p_key}->{d_key}" if p_key and d_key else ""
    verdict = "PASS" if passed else "FAIL"
    print(f"\nRESULT: {verdict}")
    if passed and pair and p_key != d_key:
        print(f"Waiting for approval: dashboard > The stack > Card compatibility, or: "
              f"bash lab/compat/62-approve-pair.sh approve {p_key}.to.{d_key}")
    elif passed and p_key and p_key == d_key:
        print("Keys are equal: the pair is already allowed; this run confirms the handoff works.")
    elif passed:
        print("Pods have no kv-compat-key yet: install lab/compat (60-compat-install.sh) and rerun to get the pair entry.")

    record = {"time": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "verdict": verdict, "pair": pair,
              "prefill": prefill_pod["metadata"]["name"], "decode": decode_pod["metadata"]["name"],
              "errors": errors, "compared": done, "first_token_same": first, "split_agreement": s_mean,
              "prefill_alone_agreement": p_mean, "checks": checks, "model": model}
    # Same entry name the labeler uses for the pair, so a manual run also updates its record.
    name = os.environ.get("RESULT_KEY") or (f"{p_key}.to.{d_key}" if p_key and d_key
                                            else f"{record['prefill']}.to.{record['decode']}")
    try:
        try:
            k8s("PATCH", f"/api/v1/namespaces/{NS}/configmaps/kv-compat-results",
                {"data": {name + ".json": json.dumps(record)}}, "application/merge-patch+json")
        except urllib.error.HTTPError as e:
            if e.code != 404:
                raise
            k8s("POST", f"/api/v1/namespaces/{NS}/configmaps",
                {"metadata": {"name": "kv-compat-results"}, "data": {name + ".json": json.dumps(record)}})
        print("saved to ConfigMap kv-compat-results")
    except Exception as ex:
        print(f"could not save the result: {ex}")
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
