#!/usr/bin/env python3
"""Hetero-PD lab dashboard backend. Python standard library only.

Serves /app/web and a small API:
  GET  /api/state          router mode, traffic run, live decision counts, run history
  POST /api/mode           {"mode": "hetero" | "guarded" | "auto" | "stock"}  switch the router's decider
  POST /api/traffic/start  {"users": 32, "docsPerSec": 0.5, "minutes": 3}
  POST /api/traffic/stop
  GET  /api/hw             live hardware readings (hw-monitor on each worker + Gaudi watchdog), last hour of history
Traffic goes to the router service, exactly like a real client.
"""
import http.client, json, os, random, re, ssl, threading, time, urllib.parse, urllib.request
from http.server import ThreadingHTTPServer, SimpleHTTPRequestHandler

NS = open("/var/run/secrets/kubernetes.io/serviceaccount/namespace").read().strip()
TOKEN = "/var/run/secrets/kubernetes.io/serviceaccount/token"
API = "https://kubernetes.default.svc"
CTX = ssl.create_default_context(cafile="/var/run/secrets/kubernetes.io/serviceaccount/ca.crt")
EPP_DEPLOY = os.environ.get("EPP_DEPLOYMENT", "hetero-pd-epp")
ROUTER_HOST = os.environ.get("ROUTER_HOST", f"hetero-pd-epp.{NS}.svc")
ROUTER_PORT = int(os.environ.get("ROUTER_PORT", "80"))
EPP_METRICS = os.environ.get("EPP_METRICS_URL", f"http://hetero-pd-epp.{NS}.svc:9090/metrics")
MODEL = os.environ.get("MODEL", "Qwen/Qwen2.5-7B-Instruct")
SELECTOR = "llm-d.ai/guide=hetero-pd"
MODES = {"hetero": "hetero-pd-config.yaml", "guarded": "guarded-pd-config.yaml", "auto": "auto-pd-config.yaml",
         "stock": "stock-pd-config.yaml", "always": "always-pd-config.yaml"}
PLUGIN_MODES = ("hetero", "guarded", "auto")   # your plugin with strategy model / guarded-stock / auto
LINE = re.compile(r'^([a-zA-Z_:][a-zA-Z0-9_:]*)(\{[^}]*\})?\s+([-+0-9.eEInfa]+)')
LABEL = re.compile(r'(\w+)="((?:[^"\\]|\\.)*)"')
lock = threading.Lock()

def tok():
    return open(TOKEN).read().strip()

def k8s(method, path, body=None, ctype="application/json"):
    req = urllib.request.Request(API + path, method=method, data=json.dumps(body).encode() if body is not None else None)
    req.add_header("Authorization", "Bearer " + tok())
    if body is not None:
        req.add_header("Content-Type", ctype)
    with urllib.request.urlopen(req, timeout=5, context=CTX) as r:
        return json.loads(r.read())

def k8s_text(path):
    req = urllib.request.Request(API + path)
    req.add_header("Authorization", "Bearer " + tok())
    with urllib.request.urlopen(req, timeout=8, context=CTX) as r:
        return r.read().decode(errors="replace")

def scrape(url, auth=False):
    req = urllib.request.Request(url)
    if auth:
        req.add_header("Authorization", "Bearer " + tok())
    with urllib.request.urlopen(req, timeout=2) as r:
        text = r.read().decode()
    out = []
    for ln in text.splitlines():
        m = LINE.match(ln) if ln and ln[0] != "#" else None
        if m:
            try:
                out.append((m.group(1), dict(LABEL.findall(m.group(2) or "")), float(m.group(3))))
            except ValueError:
                pass
    return out

# ---------------- router mode ----------------
def epp_deployment():
    return k8s("GET", f"/apis/apps/v1/namespaces/{NS}/deployments/{EPP_DEPLOY}")

def mode_state():
    try:
        d = epp_deployment()
    except Exception as ex:
        return {"current": None, "error": str(ex)[:160]}
    c = next(c for c in d["spec"]["template"]["spec"]["containers"] if c["name"] == "epp")
    args = c.get("args", [])
    cfg = args[args.index("--config-file") + 1] if "--config-file" in args else ""
    current = next((m for m, f in MODES.items() if cfg.endswith(f)), "unknown")
    st = d.get("status", {})
    ready = (st.get("observedGeneration", 0) >= d["metadata"].get("generation", 0)
             and st.get("updatedReplicas", 0) >= d["spec"].get("replicas", 1)
             and st.get("availableReplicas", 0) >= d["spec"].get("replicas", 1)
             and st.get("replicas", 0) == st.get("updatedReplicas", 0))
    return {"current": current, "ready": ready, "configFile": cfg}

def set_mode(mode):
    d = epp_deployment()
    c = next(c for c in d["spec"]["template"]["spec"]["containers"] if c["name"] == "epp")
    args = list(c.get("args", []))
    if "--config-file" not in args:
        raise RuntimeError("router has no --config-file argument")
    i = args.index("--config-file") + 1
    args[i] = "/config/" + MODES[mode]
    patch = {"spec": {"template": {"spec": {"containers": [{"name": "epp", "args": args}]}}}}
    k8s("PATCH", f"/apis/apps/v1/namespaces/{NS}/deployments/{EPP_DEPLOY}", patch, "application/strategic-merge-patch+json")

# ---------------- traffic ----------------
SERVICES = ["checkout-api", "payments-gateway", "inventory-sync", "auth-proxy", "search-indexer", "billing-worker", "ledger-db"]
CHAT_WORDS = ("please help me write a short friendly reply to a customer who asked about their order status "
              "delivery date refund policy and whether the item can be shipped faster to another address").split()
def chat_prompt(rng, tokens):
    n = max(20, int(tokens * rng.uniform(0.85, 1.15)))           # about one token per word
    return " ".join(rng.choice(CHAT_WORDS) for _ in range(n)) + "\nReply:"
def doc_prompt(rng, tokens):
    paras, total = [], 12                                       # about 38 tokens per paragraph
    target = tokens * rng.uniform(0.9, 1.1)
    while total < target:
        s = rng.choice(SERVICES)
        paras.append(f"At {rng.randint(0,23):02d}:{rng.randint(0,59):02d} UTC {s} in region-{rng.randint(1,5)} returned errors for "
                     f"{rng.randint(2,90)} seconds after a config change; {rng.randint(10,9000)} tickets were opened and the team rolled back.")
        total += 38
    return "Summarize these incident notes in three sentences.\n\n" + "\n".join(paras) + "\nSummary:"

class Run:
    def __init__(self, cfg, mode):
        self.cfg = cfg; self.mode = mode
        self.users, self.docs, self.minutes = cfg["users"], cfg["docsPerSec"], cfg["minutes"]
        self.start = time.time(); self.end = self.start + self.minutes * 60
        self.stop = threading.Event()
        self.rec = {"chat": [], "doc": []}   # (t, ttft, mean_itl, tokens, prompt_tokens)
        self.errors = 0; self.last_error = ""
        self.dec0 = decisions_total()
    def alive(self):
        return not self.stop.is_set() and time.time() < self.end

def stream(prompt, max_tokens):
    t0 = time.perf_counter(); first = None; times = []; ptoks = None
    conn = http.client.HTTPConnection(ROUTER_HOST, ROUTER_PORT, timeout=180)
    body = json.dumps({"model": MODEL, "prompt": prompt, "max_tokens": max_tokens, "temperature": 0.7, "stream": True,
                       "stream_options": {"include_usage": True}})
    conn.request("POST", "/v1/completions", body, {"Content-Type": "application/json"})
    r = conn.getresponse()
    if r.status != 200:
        raise RuntimeError(f"HTTP {r.status}: {r.read()[:120]!r}")
    buf = b""
    while True:
        chunk = r.read1(65536) if hasattr(r, "read1") else r.read(1024)
        if not chunk:
            break
        buf += chunk
        while b"\n" in buf:
            line, buf = buf.split(b"\n", 1)
            if not line.startswith(b"data:") or line.startswith(b"data: [DONE]"):
                continue
            try:
                d = json.loads(line[5:])
            except ValueError:
                d = {}
            if d.get("usage"):
                ptoks = d["usage"].get("prompt_tokens")
            if d.get("choices"):
                now = time.perf_counter()
                if first is None:
                    first = now
                times.append(now)
    conn.close()
    if first is None:
        raise RuntimeError("no tokens received")
    itl = (times[-1] - times[0]) / (len(times) - 1) if len(times) > 1 else 0.0
    return first - t0, itl, len(times), ptoks

def worker(run, kind, rng):
    p = chat_prompt(rng, run.cfg["chatTokens"]) if kind == "chat" else doc_prompt(rng, run.cfg["docTokens"])
    try:
        ttft, itl, n, pt = stream(p, 128 if kind == "chat" else 64)
        with lock:
            run.rec[kind].append((time.time(), ttft, itl, n, pt))
    except Exception as ex:
        with lock:
            run.errors += 1; run.last_error = str(ex)[:160]

def chat_user(run, seed):
    rng = random.Random(seed)
    while run.alive():
        worker(run, "chat", rng)
def doc_feeder(run):
    rng = random.Random(7)
    while run.alive() and run.docs > 0:
        threading.Thread(target=worker, args=(run, "doc", rng), daemon=True).start()
        time.sleep(rng.expovariate(run.docs))

RUN = None; HISTORY = []
DEFAULTS = {"users": 32, "docsPerSec": 0.5, "minutes": 3, "chatTokens": 250, "docTokens": 700, "scenario": None, "suite": None}
def clean_cfg(b):
    c = dict(DEFAULTS)
    c["users"] = max(0, min(96, int(b.get("users", c["users"]))))
    c["docsPerSec"] = max(0.0, min(4.0, float(b.get("docsPerSec", c["docsPerSec"]))))
    c["minutes"] = max(1, min(15, int(b.get("minutes", c["minutes"]))))
    c["chatTokens"] = max(30, min(4000, int(b.get("chatTokens", c["chatTokens"]))))
    c["docTokens"] = max(100, min(7500, int(b.get("docTokens", c["docTokens"]))))
    c["scenario"] = b.get("scenario")
    c["suite"] = b.get("suite")   # id of the test suite this run belongs to, if any
    if c["users"] == 0 and c["docsPerSec"] == 0:
        raise RuntimeError("Set some chat users or documents.")
    return c

def start_traffic(cfg):
    global RUN
    with lock:
        if RUN and RUN.alive():
            raise RuntimeError("traffic is already running")
    m = mode_state().get("current")
    run = Run(cfg, m)
    with lock:
        RUN = run
    for i in range(cfg["users"]):
        threading.Thread(target=chat_user, args=(run, i), daemon=True).start()
    threading.Thread(target=doc_feeder, args=(run,), daemon=True).start()
    threading.Thread(target=finish_when_done, args=(run,), daemon=True).start()
    return run

def finish_when_done(run):
    while run.alive():
        time.sleep(1)
    time.sleep(3)
    s = summarize(run, final=True)
    with lock:
        HISTORY.insert(0, s); del HISTORY[200:]
    save_history()
    run.done = True

def pct(vals, q):
    if not vals:
        return None
    v = sorted(vals); return v[min(len(v) - 1, int(q * (len(v) - 1) + 0.5))]

def summarize(run, final=False, window=None):
    with lock:
        rec = {k: list(v) for k, v in run.rec.items()}; errors = run.errors; last = run.last_error
    now = time.time()
    def sel(kind):
        return [r for r in rec[kind] if window is None or now - r[0] <= window]
    chat, doc = sel("chat"), sel("doc")
    dur = max(1.0, min(now, run.end) - run.start)
    d1 = decisions_total()
    moved = d1["moved"] - run.dec0["moved"]; kept = d1["kept"] - run.dec0["kept"]
    avg = lambda xs: sum(xs) / len(xs) if xs else None
    return {"mode": run.mode, "scenario": run.cfg.get("scenario"), "suite": run.cfg.get("suite"), "users": run.users, "docsPerSec": run.docs, "minutes": run.minutes,
            "chatTokens": run.cfg["chatTokens"], "docTokens": run.cfg["docTokens"],
            "chatPromptTokens": avg([r[4] for r in chat if r[4]]), "docPromptTokens": avg([r[4] for r in doc if r[4]]),
            "startedAt": run.start, "endsAt": run.end, "running": run.alive(), "final": final,
            "chatDone": len(chat), "docDone": len(doc), "errors": errors, "lastError": last,
            "chatTtftP50": pct([r[1] for r in chat], .5), "chatTtftP95": pct([r[1] for r in chat], .95),
            "chatItlP50": pct([r[2] for r in chat], .5), "chatItlP95": pct([r[2] for r in chat], .95),
            "docTtftP50": pct([r[1] for r in doc], .5), "docTtftP95": pct([r[1] for r in doc], .95),
            "tokensPerSec": sum(r[3] for r in chat + doc) / dur, "moved": moved, "kept": kept}

# ---------------- saved results (a ConfigMap, so restarts keep them) ----------------
CM = "hetero-pd-dashboard-results"
def load_history():
    global HISTORY
    try:
        cm = k8s("GET", f"/api/v1/namespaces/{NS}/configmaps/{CM}")
        HISTORY = json.loads(cm.get("data", {}).get("history.json", "[]"))
    except Exception:
        HISTORY = []
def save_history():
    with lock:
        data = json.dumps(HISTORY)
    body = {"apiVersion": "v1", "kind": "ConfigMap", "metadata": {"name": CM}, "data": {"history.json": data}}
    try:
        k8s("PUT", f"/api/v1/namespaces/{NS}/configmaps/{CM}", body)
    except Exception:
        try:
            k8s("POST", f"/api/v1/namespaces/{NS}/configmaps", body)
        except Exception:
            pass

# ---------------- test suite ----------------
SCENARIOS = {
    "busy-chat":    {"name": "Busy chat",                   "users": 32, "docsPerSec": 0,   "chatTokens": 250, "docTokens": 700},
    "busy-medium":  {"name": "Busy + medium documents",     "users": 32, "docsPerSec": 0.5, "chatTokens": 250, "docTokens": 700},
    "busy-long":    {"name": "Busy + long documents",       "users": 32, "docsPerSec": 0.5, "chatTokens": 250, "docTokens": 2000},
    "idle-long":    {"name": "Idle + long documents",       "users": 0,  "docsPerSec": 0.5, "chatTokens": 250, "docTokens": 2000},
    "busy-huge":    {"name": "Busy + very long reports",    "users": 32, "docsPerSec": 0.2, "chatTokens": 250, "docTokens": 6000},
    "light-chat":   {"name": "Light chat",                  "users": 8,  "docsPerSec": 0,   "chatTokens": 250, "docTokens": 700},
}
SUITE = {"running": False}
def wait_mode(mode, timeout=240):
    t0 = time.time()
    while time.time() - t0 < timeout:
        st = mode_state()
        if st.get("current") == mode and st.get("ready"):
            time.sleep(20)          # let the new router find the model servers
            return True
        if SUITE.get("stop"):
            return False
        time.sleep(3)
    return False

def suite_thread(ids, repeats, minutes, modes):
    try:
        order = ["stock"] + list(modes)   # alternate the order each repeat so warm-up effects cancel out
        steps = [(sid, mode, r) for r in range(repeats) for sid in ids for mode in (order if r % 2 == 0 else order[::-1])]
        SUITE.update(running=True, total=len(steps), done=0, current=None, error=None, stop=False, started=time.time(), ids=ids, repeats=repeats, minutes=minutes, modes=list(modes))
        start_mode = mode_state().get("current")
        for sid, mode, r in steps:
            if SUITE.get("stop"):
                break
            SUITE["current"] = {"scenario": sid, "name": SCENARIOS[sid]["name"], "mode": mode, "repeat": r + 1}
            if mode_state().get("current") != mode:
                set_mode(mode)
                time.sleep(5)
            if not wait_mode(mode):
                SUITE["error"] = f"Router did not become ready in {mode} mode."
                break
            cfg = clean_cfg(dict(SCENARIOS[sid], minutes=minutes, scenario=sid, suite=int(SUITE["started"])))
            run = start_traffic(cfg)
            while not getattr(run, "done", False):
                if SUITE.get("stop"):
                    run.stop.set()
                time.sleep(2)
            SUITE["done"] += 1
        if start_mode in MODES and start_mode != "always" and mode_state().get("current") != start_mode:
            set_mode(start_mode)
    except Exception as ex:
        SUITE["error"] = str(ex)[:200]
    finally:
        SUITE["running"] = False; SUITE["current"] = None

# ---------------- decisions + pods ----------------
def decisions_total():
    try:
        e = scrape(EPP_METRICS, auth=True)
    except Exception:
        return {"moved": 0, "kept": 0, "reasons": {}, "ok": False}
    moved = kept = 0; reasons = {}
    for n, l, v in e:
        if n == "llm_d_epp_disagg_decision_total":
            if "prefill" in l.get("decision_type", ""):
                moved += v
            else:
                kept += v
        elif n == "llm_d_epp_hetero_pd_decision_total":
            reasons[l.get("reason", "?")] = reasons.get(l.get("reason", "?"), 0) + v
    return {"moved": moved, "kept": kept, "reasons": reasons, "ok": True}

LIVE = {"t": 0, "pods": [], "dec": {"moved": 0, "kept": 0, "reasons": {}, "ok": False}, "rate": {"moved": 0, "kept": 0}}
def live_loop():
    prev = None
    while True:
        try:
            items = k8s("GET", f"/api/v1/namespaces/{NS}/pods?labelSelector={urllib.parse.quote(SELECTOR)}")["items"]
            pods = []
            for p in items:
                if p["status"].get("phase") != "Running" or not p["status"].get("podIP"):
                    continue
                lab = p["metadata"].get("labels", {})
                port = next((pt["containerPort"] for c in p["spec"]["containers"] for pt in c.get("ports", []) if pt.get("name") == "modelserver"), 8000)
                info = {"name": p["metadata"]["name"], "role": lab.get("llm-d.ai/role", ""), "cls": lab.get("llm-d.ai/accelerator-class", ""), "running": 0, "waiting": 0, "kv": 0, "up": False}
                try:
                    s = scrape(f"http://{p['status']['podIP']}:{port}/metrics")
                    g = lambda n: sum(v for nm, l, v in s if nm == n)
                    info.update(running=g("vllm:num_requests_running"), waiting=g("vllm:num_requests_waiting"),
                                kv=g("vllm:kv_cache_usage_perc"), up=True)
                except Exception:
                    pass
                pods.append(info)
            dec = decisions_total(); now = time.time()
            rate = LIVE["rate"]
            if prev and dec["ok"]:
                dt = max(1e-3, now - prev[0])
                rate = {"moved": (dec["moved"] - prev[1]["moved"]) * 60 / dt, "kept": (dec["kept"] - prev[1]["kept"]) * 60 / dt}
            if dec["ok"]:
                prev = (now, dec)
            with lock:
                LIVE.update(t=now, pods=pods, dec=dec, rate=rate)
        except Exception:
            pass
        time.sleep(5)


# ---------------- live hardware (Stack tab) ----------------
HW = {"t": 0, "nodes": [], "gaudi": [], "gaudiNode": "", "watchdog": [], "series": {}}
WD = re.compile(r"^csv,(\d\d:\d\d:\d\d),([^,]+),([-0-9.]+),([-0-9.]+),([-0-9.]+),([-0-9.]+)")
def wd_time(hms, now):
    import datetime
    d = datetime.datetime.fromtimestamp(now, datetime.timezone.utc).date()
    t = datetime.datetime.strptime(f"{d} {hms}", "%Y-%m-%d %H:%M:%S").replace(tzinfo=datetime.timezone.utc).timestamp()
    return t - 86400 if t > now + 120 else t

def hw_loop():
    series, gaudi_last, first, gnode, k = {}, {}, True, "", 0
    def add(key, t, v):
        if v is None:
            return
        a = series.setdefault(key, [])
        if not a or t > a[-1][0]:
            a.append([round(t), round(v, 1)])
    while True:
        now = time.time(); nodes = []
        try:
            for p in k8s("GET", f"/api/v1/namespaces/{NS}/pods?labelSelector=app%3Dhw-monitor")["items"]:
                ip, nn = p["status"].get("podIP"), p["spec"].get("nodeName", "?")
                if not ip or p["status"].get("phase") != "Running":
                    nodes.append({"node": nn, "error": "starting"}); continue
                try:
                    with urllib.request.urlopen(f"http://{ip}:9477/json", timeout=3) as r:
                        nodes.append(json.loads(r.read()))
                except Exception as ex:
                    nodes.append({"node": nn, "error": "no answer from hw-monitor: " + str(ex)[:80]})
        except Exception as ex:
            nodes = [{"node": "?", "error": "hw-monitor not readable: " + str(ex)[:100]}]
        if k % 60 == 0:
            try:
                gnode = next((n["metadata"]["name"] for n in k8s("GET", "/api/v1/nodes")["items"]
                              if float(n["status"].get("allocatable", {}).get("habana.ai/gaudi", "0") or 0) > 0), gnode)
            except Exception:
                pass
        msgs = []
        try:
            wp = [p for p in k8s("GET", f"/api/v1/namespaces/{NS}/pods?labelSelector=app%3Dgaudi-watchdog")["items"]
                  if p["status"].get("phase") == "Running"]
            if wp:
                txt = k8s_text(f"/api/v1/namespaces/{NS}/pods/{wp[0]['metadata']['name']}/log?sinceSeconds={3600 if first else 30}")
                first = False
                for ln in txt.splitlines():
                    m = WD.match(ln)
                    if m:
                        t = wd_time(m.group(1), now); ser = m.group(2)
                        gaudi_last[ser] = {"serial": ser, "t": t, "c": float(m.group(3)), "board": float(m.group(4)), "w": float(m.group(5)), "util": float(m.group(6))}
                        add("gaudi:" + ser, t, float(m.group(3)))
                    elif ln.startswith("WATCHDOG"):
                        msgs.append(ln[:200])
        except Exception as ex:
            msgs.append("watchdog log not readable: " + str(ex)[:100])
        sers = sorted(gaudi_last)
        gaudi = [dict(gaudi_last[s], id=f"Gaudi 3 #{i + 1}", stale=now - gaudi_last[s]["t"] > 30) for i, s in enumerate(sers)]
        for n in nodes:
            sh = n.get("node", "?").split(".")[0]
            if n.get("error"):
                continue
            add(sh + ":power", now, n.get("power"))
            z = [x["pct"] for x in n.get("zones", [])]
            add(sh + ":fanpct", now, sum(z) / len(z) if z else None)
            r = [x["rpm"] for x in n.get("fans", [])]
            add(sh + ":fanrpm", now, sum(r) / len(r) if r else None)
            inl = next((x["c"] for x in n.get("temps", []) if re.search(r"inlet|ambient", x["name"], re.I)), None)
            add(sh + ":inlet", now, inl)
            for c in n.get("cards", []):
                add(sh + ":card:" + c["id"], now, c.get("c"))
        for key in list(series):
            series[key] = [p for p in series[key] if p[0] >= now - 3600]
        with lock:
            HW.update(t=now, nodes=nodes, gaudi=gaudi, gaudiNode=gnode, watchdog=(HW["watchdog"] + msgs)[-6:],
                      series={key: v for key, v in series.items()})
        k += 1
        time.sleep(5)

def thin(pts, step=20):
    out, last = [], -1e18
    for p in pts:
        if p[0] - last >= step:
            out.append(p); last = p[0]
    if pts and out[-1] is not pts[-1]:
        out.append(pts[-1])
    return out


# ---------------- heat test (Stack tab): load straight onto the cards, watch fans and temperatures ----------------
GAUDI_DEP = os.environ.get("GAUDI_DEPLOYMENT", "decode-gaudi3")
HEAT_GUARD_GAUDI = float(os.environ.get("HEAT_GUARD_GAUDI_C", "78"))   # the watchdog stops everything at 80
HEAT_GUARD_A30 = float(os.environ.get("HEAT_GUARD_A30_C", "85"))
HEAT = {"running": False, "target": "", "phase": "idle", "msg": "", "users": 0, "minutes": 0, "cards": 0,
        "started": 0, "until": 0, "done": 0, "errors": 0, "tokens": 0, "lastErr": "", "windows": []}
HEAT_STOP = threading.Event()
WORDS = ("the server room was quiet until the fans began to rise while engineers measured power heat airflow and "
         "temperature across every card in the rack noting how quickly each chip warmed under steady load and how "
         "the controller answered with more air or none at all as the minutes passed").split()

def pod_ready(p):
    return any(c.get("type") == "Ready" and c.get("status") == "True" for c in p["status"].get("conditions", []))

def card_pods(cls_part):
    out = []
    for p in k8s("GET", f"/api/v1/namespaces/{NS}/pods?labelSelector={urllib.parse.quote(SELECTOR)}")["items"]:
        lab = p["metadata"].get("labels", {})
        if cls_part not in lab.get("llm-d.ai/accelerator-class", "") or p["status"].get("phase") != "Running" or not pod_ready(p):
            continue
        port = next((pt["containerPort"] for c in p["spec"]["containers"] for pt in c.get("ports", []) if pt.get("name") == "modelserver"), 8000)
        out.append((p["metadata"]["name"], p["status"]["podIP"], port))
    return out

def heat_worker(ip, port):
    while not HEAT_STOP.is_set() and time.time() < HEAT["until"]:
        prompt = " ".join(random.choice(WORDS) for _ in range(1000))
        body = json.dumps({"model": MODEL, "prompt": prompt, "max_tokens": 256, "temperature": 0.8, "ignore_eos": True})
        try:
            conn = http.client.HTTPConnection(ip, port, timeout=180)
            conn.request("POST", "/v1/completions", body, {"Content-Type": "application/json"})
            r = conn.getresponse(); data = r.read(); conn.close()
            if r.status != 200:
                raise RuntimeError(f"HTTP {r.status}: {data[:100]!r}")
            u = json.loads(data).get("usage", {})
            with lock:
                HEAT["done"] += 1; HEAT["tokens"] += u.get("prompt_tokens", 0) + u.get("completion_tokens", 0)
        except Exception as ex:
            with lock:
                HEAT["errors"] += 1; HEAT["lastErr"] = str(ex)[:160]
            HEAT_STOP.wait(2)

def heat_guard():
    """Stop reason if a card is too hot, else ''."""
    with lock:
        g = list(HW.get("gaudi", [])); nodes = list(HW.get("nodes", []))
    for x in g:
        if x.get("c") is not None and x["c"] >= HEAT_GUARD_GAUDI and not x.get("stale"):
            return f"{x['id']} reached {x['c']:.0f} °C (heat test stops at {HEAT_GUARD_GAUDI:.0f} °C)"
    for n in nodes:
        for c in n.get("cards", []):
            lim = min(HEAT_GUARD_A30, (c.get("slowdown") or 99) - 3)
            if c.get("c") is not None and c["c"] >= lim:
                return f"{c['id']} reached {c['c']:.0f} °C (heat test stops at {lim:.0f} °C)"
    return ""

def scale_gaudi(n):
    k8s("PATCH", f"/apis/apps/v1/namespaces/{NS}/deployments/{GAUDI_DEP}/scale", {"spec": {"replicas": n}}, "application/merge-patch+json")

def heat_thread(target, users, minutes, cards):
    prev = None; win = None; threads = []
    def phase(p, m=""):
        with lock:
            HEAT.update(phase=p, msg=m)
    try:
        if target in ("gaudi", "both"):
            prev = int(k8s("GET", f"/apis/apps/v1/namespaces/{NS}/deployments/{GAUDI_DEP}")["spec"].get("replicas") or 0)
            if prev < cards:
                scale_gaudi(cards)
            t0 = time.time()
            while len(card_pods("gaudi")) < cards:
                why = heat_guard()
                if why:
                    raise RuntimeError("stopped during Gaudi start-up: " + why)
                if HEAT_STOP.is_set():
                    raise RuntimeError("stopped before the load started")
                if time.time() - t0 > 1500:
                    raise RuntimeError("Gaudi model server did not become ready within 25 minutes")
                phase("starting", f"Starting {cards} Gaudi model server{'s' if cards > 1 else ''}: loading and warming up takes several minutes "
                                  f"({int(time.time() - t0)} s so far). Temperatures are already being watched.")
                HEAT_STOP.wait(5)
        pods = []
        if target in ("gaudi", "both"):
            pods += card_pods("gaudi")[:cards]
        if target in ("a30", "both"):
            a = card_pods("a30")
            if not a:
                raise RuntimeError("no running A30 model server found")
            pods += a
        with lock:
            HEAT.update(started=time.time(), until=time.time() + minutes * 60)
            win = {"start": round(time.time()), "end": None, "target": target, "users": users}
            HEAT["windows"] = (HEAT["windows"] + [win])[-10:]
        phase("load", f"Load running on {', '.join(p[0] for p in pods)}: {users} request{'s' if users > 1 else ''} at a time on each.")
        for _, ip, port in pods:
            for _ in range(users):
                t = threading.Thread(target=heat_worker, args=(ip, port), daemon=True); t.start(); threads.append(t)
        while time.time() < HEAT["until"] and not HEAT_STOP.is_set():
            why = heat_guard()
            if why:
                HEAT_STOP.set(); phase("stopped", "Safety stop: " + why); break
            HEAT_STOP.wait(2)
        HEAT_STOP.set()
        for t in threads:
            t.join(timeout=200)
        if HEAT["phase"] != "stopped":
            phase("done", "Finished." if time.time() >= HEAT["until"] - 2 else "Stopped.")
    except Exception as ex:
        HEAT_STOP.set(); phase("stopped", str(ex)[:200])
    finally:
        HEAT_STOP.set()
        if win is not None:
            win["end"] = round(time.time())
        if prev is not None and prev < cards:
            try:
                scale_gaudi(prev)
                with lock:
                    HEAT["msg"] += f" Gaudi model server scaled back to {prev}; the cards now cool down."
            except Exception as ex:
                with lock:
                    HEAT["msg"] += f" Could not scale the Gaudi model server back to {prev}: {ex}"
        with lock:
            HEAT["running"] = False

def start_heat(b):
    target = b.get("target")
    if target not in ("a30", "gaudi", "both"):
        raise ValueError("target must be a30, gaudi or both")
    users = max(1, min(32, int(b.get("users", 2)))); minutes = max(1, min(15, int(b.get("minutes", 3))))
    cards = max(1, min(2, int(b.get("gaudiCards", 1))))
    why = heat_guard()
    if why and target != "a30":
        raise ValueError("Too hot to start: " + why)
    HEAT_STOP.clear()
    with lock:
        HEAT.update(running=True, target=target, users=users, minutes=minutes, cards=cards, phase="starting", msg="Starting…",
                    started=0, until=0, done=0, errors=0, tokens=0, lastErr="")
    threading.Thread(target=heat_thread, args=(target, users, minutes, cards), daemon=True).start()

# ---------------- http ----------------
class H(SimpleHTTPRequestHandler):
    extensions_map = {**SimpleHTTPRequestHandler.extensions_map, ".html": "text/html; charset=utf-8", ".json": "application/json; charset=utf-8"}
    def __init__(self, *a, **k):
        super().__init__(*a, directory="/app/web", **k)
    def log_message(self, *a):
        pass
    def send_json(self, obj, code=200):
        b = json.dumps(obj).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Cache-Control", "no-store"); self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def body(self):
        n = int(self.headers.get("Content-Length", "0") or 0)
        return json.loads(self.rfile.read(n) or b"{}")
    def do_GET(self):
        if self.path.startswith("/healthz"):
            return self.send_json({"ok": True})
        if self.path.startswith("/api/state"):
            with lock:
                run = RUN; hist = list(HISTORY); live = dict(LIVE)
            return self.send_json({"mode": mode_state(), "traffic": summarize(run, window=30) if run else None,
                                   "trafficTotal": summarize(run) if run else None, "history": hist, "live": live, "model": MODEL,
                                   "suite": {k: v for k, v in SUITE.items() if k != "stop"},
                                   "scenarios": {k: v["name"] for k, v in SCENARIOS.items()}})
        if self.path.startswith("/api/hw"):
            with lock:
                h = dict(HW); ser = {k: thin(v) for k, v in HW["series"].items()}
                h["heat"] = dict(HEAT, windows=[dict(w) for w in HEAT["windows"]])
            h["series"] = ser
            return self.send_json(h)
        return super().do_GET()
    def do_POST(self):
        try:
            b = self.body()
            if self.path == "/api/mode":
                m = b.get("mode")
                if m not in MODES:   # "always" is accepted for the correctness tests but not offered in the page
                    return self.send_json({"error": "mode must be one of " + ", ".join(MODES)}, 400)
                if (RUN and RUN.alive()) or SUITE.get("running"):
                    return self.send_json({"error": "Stop the traffic before switching the router."}, 409)
                set_mode(m); return self.send_json({"ok": True})
            if self.path == "/api/heat/start":
                if HEAT.get("running"):
                    return self.send_json({"error": "A heat test is already running."}, 409)
                if (RUN and RUN.alive()) or SUITE.get("running"):
                    return self.send_json({"error": "Stop the traffic or test suite first."}, 409)
                try:
                    start_heat(b)
                except ValueError as ex:
                    return self.send_json({"error": str(ex)}, 400)
                return self.send_json({"ok": True})
            if self.path == "/api/heat/stop":
                HEAT_STOP.set(); return self.send_json({"ok": True})
            if self.path == "/api/traffic/start":
                if HEAT.get("running"):
                    return self.send_json({"error": "A heat test is running (Stack tab)."}, 409)
                if SUITE.get("running"):
                    return self.send_json({"error": "A test suite is running."}, 409)
                if not mode_state().get("ready"):
                    return self.send_json({"error": "The router is restarting. Try again in a moment."}, 409)
                start_traffic(clean_cfg(b)); return self.send_json({"ok": True})
            if self.path == "/api/traffic/stop":
                SUITE["stop"] = True; HEAT_STOP.set()   # the Gaudi watchdog calls this too
                if RUN:
                    RUN.stop.set()
                return self.send_json({"ok": True})
            if self.path == "/api/suite/start":
                if SUITE.get("running") or (RUN and RUN.alive()):
                    return self.send_json({"error": "Something is already running."}, 409)
                ids = [i for i in b.get("scenarios", []) if i in SCENARIOS]
                if not ids:
                    return self.send_json({"error": "Pick at least one scenario."}, 400)
                modes = [m for m in PLUGIN_MODES if m in b.get("modes", ["auto"])]
                if not modes:
                    return self.send_json({"error": "Pick at least one plugin strategy to compare with stock."}, 400)
                reps = max(1, min(3, int(b.get("repeats", 1)))); mins = max(1, min(10, int(b.get("minutes", 3))))
                SUITE.update(running=True, stop=False)
                threading.Thread(target=suite_thread, args=(ids, reps, mins, modes), daemon=True).start()
                return self.send_json({"ok": True})
            if self.path == "/api/history/clear":
                with lock:
                    HISTORY.clear()
                save_history(); return self.send_json({"ok": True})
            return self.send_json({"error": "not found"}, 404)
        except Exception as ex:
            return self.send_json({"error": str(ex)[:200]}, 500)

load_history()
threading.Thread(target=live_loop, daemon=True).start()
threading.Thread(target=hw_loop, daemon=True).start()
ThreadingHTTPServer(("0.0.0.0", 8080), H).serve_forever()
