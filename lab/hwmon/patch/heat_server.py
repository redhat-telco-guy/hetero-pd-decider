
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
