#!/usr/bin/env python3
"""Hetero-PD dashboard backend. Standard library only.

Serves the dashboard page and results.json from /app/web, and /live.json with
a rolling 15-minute history scraped every 2 s from:
  - the router (EPP) /metrics: hetero-pd and stock disagg decision counters
  - every model-server pod labelled llm-d.ai/guide=hetero-pd: vLLM /metrics
Pods are found through the Kubernetes API with this pod's service account.
"""
import json, os, re, ssl, threading, time, urllib.parse, urllib.request
from http.server import ThreadingHTTPServer, SimpleHTTPRequestHandler

NS = open("/var/run/secrets/kubernetes.io/serviceaccount/namespace").read().strip()
TOKEN_PATH = "/var/run/secrets/kubernetes.io/serviceaccount/token"
CA = "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
API = "https://kubernetes.default.svc"
EPP_URL = os.environ.get("EPP_METRICS_URL", f"http://hetero-pd-epp.{NS}.svc:9090/metrics")
SELECTOR = os.environ.get("POD_SELECTOR", "llm-d.ai/guide=hetero-pd")
INTERVAL = float(os.environ.get("INTERVAL", "2"))
KEEP = int(900 / INTERVAL)

api_ctx = ssl.create_default_context(cafile=CA)
LINE = re.compile(r'^([a-zA-Z_:][a-zA-Z0-9_:]*)(\{[^}]*\})?\s+([-+0-9.eEInfa]+)')
LABEL = re.compile(r'(\w+)="((?:[^"\\]|\\.)*)"')

def token():
    return open(TOKEN_PATH).read().strip()

def get(url, auth=False, ctx=None, timeout=1.5):
    req = urllib.request.Request(url)
    if auth:
        req.add_header("Authorization", "Bearer " + token())
    with urllib.request.urlopen(req, timeout=timeout, context=ctx) as r:
        return r.read().decode()

def parse(text):
    out = []
    for ln in text.splitlines():
        if not ln or ln[0] == "#":
            continue
        m = LINE.match(ln)
        if not m:
            continue
        try:
            v = float(m.group(3))
        except ValueError:
            continue
        out.append((m.group(1), dict(LABEL.findall(m.group(2) or "")), v))
    return out

def total(samples, name, **match):
    return sum(v for n, l, v in samples if n == name and all(l.get(k) == w for k, w in match.items()))

def first(samples, *names):
    for nm in names:
        vals = [v for n, l, v in samples if n == nm]
        if vals:
            return sum(vals)
    return None

state = {"history": [], "pods": {}, "epp": {}, "errors": {}, "started": time.time()}
lock = threading.Lock()

def pods():
    url = f"{API}/api/v1/namespaces/{NS}/pods?labelSelector={urllib.parse.quote(SELECTOR)}"
    items = json.loads(get(url, auth=True, ctx=api_ctx))["items"]
    out = []
    for p in items:
        if p["status"].get("phase") != "Running" or not p["status"].get("podIP"):
            continue
        lab = p["metadata"].get("labels", {})
        ports = [pt.get("containerPort") for ctr in p["spec"]["containers"] for pt in ctr.get("ports", []) if pt.get("name") == "modelserver"]
        out.append({"name": p["metadata"]["name"], "ip": p["status"]["podIP"], "node": p["spec"].get("nodeName", ""),
                    "role": lab.get("llm-d.ai/role", ""), "cls": lab.get("llm-d.ai/accelerator-class", ""),
                    "port": ports[0] if ports else 8000,
                    "ready": all(cs.get("ready") for cs in p["status"].get("containerStatuses", []))})
    return out


def scrape():
    now = time.time()
    sample = {"t": now, "pods": {}, "epp": {}}
    errors = {}
    try:
        e = parse(get(EPP_URL, auth=True))
        dec = {}
        for n, l, v in e:
            if n == "llm_d_epp_hetero_pd_decision_total":
                key = l.get("reason", "?") + "|" + l.get("remote_prefill", "?")
                dec[key] = dec.get(key, 0) + v
        stock = {}
        for n, l, v in e:
            if n == "llm_d_epp_disagg_decision_total":
                key = l.get("plugin_type", "?") + "|" + l.get("decision_type", "?")
                stock[key] = stock.get(key, 0) + v
        sample["epp"] = {"hetero": dec, "disagg": stock,
                         "requests": first(e, "inference_objective_request_total", "llm_d_epp_request_total")}
    except Exception as ex:
        errors["router"] = str(ex)[:200]
    try:
        plist = pods()
    except Exception as ex:
        plist = []
        errors["kubernetes"] = str(ex)[:200]
    for p in plist:
        try:
            s = parse(get(f"http://{p['ip']}:{p['port']}/metrics"))
            ttft_s, ttft_n = first(s, "vllm:time_to_first_token_seconds_sum"), first(s, "vllm:time_to_first_token_seconds_count")
            itl_s = first(s, "vllm:inter_token_latency_seconds_sum", "vllm:time_per_output_token_seconds_sum")
            itl_n = first(s, "vllm:inter_token_latency_seconds_count", "vllm:time_per_output_token_seconds_count")
            sample["pods"][p["name"]] = {
                "running": first(s, "vllm:num_requests_running") or 0,
                "waiting": first(s, "vllm:num_requests_waiting") or 0,
                "kv": first(s, "vllm:kv_cache_usage_perc", "vllm:gpu_cache_usage_perc") or 0,
                "prompt_tokens": first(s, "vllm:prompt_tokens_total") or 0,
                "gen_tokens": first(s, "vllm:generation_tokens_total") or 0,
                "ext_hits": first(s, "vllm:external_prefix_cache_hits_total") or 0,
                "ttft_sum": ttft_s or 0, "ttft_n": ttft_n or 0, "itl_sum": itl_s or 0, "itl_n": itl_n or 0,
            }
        except Exception as ex:
            errors[p["name"]] = str(ex)[:200]
    with lock:
        state["pods"] = {p["name"]: p for p in plist}
        state["errors"] = errors
        state["history"].append(sample)
        del state["history"][:-KEEP]

def loop():
    while True:
        t0 = time.time()
        try:
            scrape()
        except Exception as ex:
            with lock:
                state["errors"]["scraper"] = str(ex)[:200]
        time.sleep(max(0.2, INTERVAL - (time.time() - t0)))

class H(SimpleHTTPRequestHandler):
    extensions_map = {**SimpleHTTPRequestHandler.extensions_map,
                      ".html": "text/html; charset=utf-8", ".json": "application/json; charset=utf-8"}
    def __init__(self, *a, **k):
        super().__init__(*a, directory="/app/web", **k)
    def log_message(self, *a):
        pass
    def end_headers(self):
        self.send_header("Cache-Control", "no-store")
        super().end_headers()
    def do_GET(self):
        if self.path.startswith("/live.json"):
            with lock:
                body = json.dumps({"now": time.time(), "interval": INTERVAL, "pods": state["pods"],
                                   "errors": state["errors"], "history": state["history"]}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if self.path.startswith("/healthz"):
            self.send_response(200); self.end_headers(); self.wfile.write(b"ok"); return
        return super().do_GET()

threading.Thread(target=loop, daemon=True).start()
ThreadingHTTPServer(("0.0.0.0", 8080), H).serve_forever()
