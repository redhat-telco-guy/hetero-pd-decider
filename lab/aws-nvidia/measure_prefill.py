#!/usr/bin/env python3
"""Measure each model server's prefill speed (prompt tokens per second), in the cluster.

For every running pod with an llm-d.ai/role label: one warm-up call, then REPEATS calls of
a long prompt with max_tokens=1 and a fresh cache_salt (so nothing is cached). Speed is
prompt_tokens / time for the fastest-but-one call, which drops one-off hiccups. Prints
'class tokens_per_sec' per accelerator class, slowest pod of a class wins.
"""
import json, os, random, ssl, time, urllib.parse, urllib.request, uuid

NS = open("/var/run/secrets/kubernetes.io/serviceaccount/namespace").read().strip()
API = "https://kubernetes.default.svc"
CTX = ssl.create_default_context(cafile="/var/run/secrets/kubernetes.io/serviceaccount/ca.crt")
MODEL = os.environ["MODEL"]
WORDS = int(os.environ.get("WORDS", "2500"))
REPEATS = int(os.environ.get("REPEATS", "5"))


def k8s(path):
    req = urllib.request.Request(API + path)
    req.add_header("Authorization", "Bearer " + open("/var/run/secrets/kubernetes.io/serviceaccount/token").read().strip())
    with urllib.request.urlopen(req, timeout=15, context=CTX) as r:
        return json.loads(r.read())


def call(hp, prompt):
    body = {"model": MODEL, "prompt": prompt, "max_tokens": 1, "temperature": 0, "cache_salt": uuid.uuid4().hex}
    req = urllib.request.Request(f"http://{hp}/v1/completions", data=json.dumps(body).encode(), method="POST",
                                 headers={"Content-Type": "application/json"})
    t0 = time.perf_counter()
    with urllib.request.urlopen(req, timeout=300) as r:
        j = json.loads(r.read())
    return j["usage"]["prompt_tokens"], time.perf_counter() - t0


rng = random.Random(3)
words = "service latency request cache region error timeout deploy gateway queue disk memory alert owner".split()
best = {}
for p in k8s(f"/api/v1/namespaces/{NS}/pods?labelSelector={urllib.parse.quote('llm-d.ai/role')}")["items"]:
    if p["status"].get("phase") != "Running":
        continue
    labels = p["metadata"]["labels"]
    cls = labels.get("llm-d.ai/accelerator-class", "unknown")
    port = next((pt["containerPort"] for c in p["spec"]["containers"] for pt in c.get("ports", []) if pt.get("name") == "modelserver"), 8000)
    hp = f"{p['status']['podIP']}:{port}"
    prompt = " ".join(rng.choice(words) for _ in range(WORDS))
    try:
        call(hp, prompt)  # warm-up
        runs = sorted(n / t for n, t in (call(hp, prompt) for _ in range(REPEATS)))
    except Exception as ex:
        print(f"# {p['metadata']['name']}: failed: {ex}")
        continue
    rate = runs[-2] if len(runs) > 1 else runs[0]
    print(f"# {p['metadata']['name']} ({cls}): {[round(r) for r in runs]} tokens/s, using {rate:.0f}")
    best[cls] = min(best.get(cls, rate), rate)
for cls, rate in sorted(best.items()):
    print(f"{cls} {rate:.0f}")
