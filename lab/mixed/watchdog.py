"""In-cluster Gaudi temperature watchdog.

Runs as a pod next to the model servers, so it keeps protecting the cards when the laptop that started
a test loses its connection. Every EVERY seconds it reads each Gaudi's temperatures from the Habana
metric exporter. If a card reaches LIMIT, or no reading arrives for BLIND_S seconds while a Gaudi model
server is running, it scales every deployment that requests habana.ai/gaudi to 0 and stops dashboard
traffic. Each reading is printed as a CSV line: oc logs deploy/gaudi-watchdog gives the full record.
"""
import json, os, re, ssl, time, urllib.request

NS = os.environ.get("NS", "hetero-pd-lab")
HNS = os.environ.get("HNS", "habana-ai-operator")
LIMIT = float(os.environ.get("LIMIT", "80"))
EVERY = float(os.environ.get("EVERY", "5"))
BLIND_S = float(os.environ.get("BLIND_S", "30"))
API = "https://kubernetes.default.svc"
TOKEN_F = "/var/run/secrets/kubernetes.io/serviceaccount/token"
CTX = ssl.create_default_context(cafile="/var/run/secrets/kubernetes.io/serviceaccount/ca.crt")
PAT = re.compile(r'(habanalabs_temperature_onchip|habanalabs_temperature_onboard|habanalabs_power_mW|habanalabs_utilization)\{.*Serial="([^"]+)".*\} (\S+)')


def k8s(method, path, body=None, ctype="application/json"):
    req = urllib.request.Request(API + path, method=method, data=json.dumps(body).encode() if body is not None else None)
    req.add_header("Authorization", "Bearer " + open(TOKEN_F).read().strip())
    if body is not None:
        req.add_header("Content-Type", ctype)
    return json.loads(urllib.request.urlopen(req, context=CTX, timeout=5).read() or b"{}")


def exporters():
    pods = k8s("GET", f"/api/v1/namespaces/{HNS}/pods")["items"]
    out = []
    for p in pods:
        if "metric-exporter" in p["metadata"]["name"] and p["status"].get("podIP"):
            port = p["spec"]["containers"][0]["ports"][0]["containerPort"]
            out.append(f"http://{p['status']['podIP']}:{port}/metrics")
    return out


def gaudi_deployments():
    deps = k8s("GET", f"/apis/apps/v1/namespaces/{NS}/deployments")["items"]
    hit = []
    for d in deps:
        for c in d["spec"]["template"]["spec"].get("containers", []):
            if "habana.ai/gaudi" in json.dumps(c.get("resources", {})):
                hit.append((d["metadata"]["name"], d["spec"].get("replicas", 0)))
                break
    return hit


def stop_all(why):
    print(f"WATCHDOG {time.strftime('%H:%M:%S')}: {why} -> stopping Gaudi model servers and traffic", flush=True)
    for name, replicas in gaudi_deployments():
        if replicas:
            k8s("PATCH", f"/apis/apps/v1/namespaces/{NS}/deployments/{name}/scale", {"spec": {"replicas": 0}}, "application/merge-patch+json")
            print(f"  scaled {name} to 0", flush=True)
    try:
        urllib.request.urlopen(urllib.request.Request(f"http://hetero-pd-dashboard.{NS}.svc:8080/api/traffic/stop", data=b"{}",
                               headers={"Content-Type": "application/json"}), timeout=5)
        print("  dashboard traffic stopped", flush=True)
    except Exception as ex:
        print(f"  dashboard traffic stop failed: {ex}", flush=True)


print(f"WATCHDOG started {time.strftime('%H:%M:%S')}: limit {LIMIT:.0f} C, every {EVERY:.0f} s, blind limit {BLIND_S:.0f} s", flush=True)
print("csv,time,serial,chip_c,board_c,power_w,util_pct", flush=True)
last_ok = time.time()
tripped_at = 0.0
while True:
    try:
        vals = {}
        for url in exporters():
            for line in urllib.request.urlopen(url, timeout=3).read().decode().splitlines():
                m = PAT.match(line)
                if m:
                    vals.setdefault(m.group(2), {})[m.group(1)] = float(m.group(3))
        if not vals:
            raise RuntimeError("no Gaudi readings")
        last_ok = time.time()
        t = time.strftime("%H:%M:%S")
        hottest = 0.0
        for s, d in sorted(vals.items()):
            c, b = d.get("habanalabs_temperature_onchip", 0), d.get("habanalabs_temperature_onboard", 0)
            hottest = max(hottest, c, b)
            print(f"csv,{t},{s},{c:.0f},{b:.0f},{d.get('habanalabs_power_mW', 0) / 1000:.0f},{d.get('habanalabs_utilization', 0):.0f}", flush=True)
        if hottest >= LIMIT and time.time() - tripped_at > 60:
            tripped_at = time.time()
            stop_all(f"a Gaudi reached {hottest:.0f} C")
    except Exception as ex:
        if "429" in str(ex):
            time.sleep(EVERY)   # the exporter rate-limits readers: back off one extra interval
        gap = time.time() - last_ok
        print(f"WATCHDOG {time.strftime('%H:%M:%S')}: no reading for {gap:.0f} s ({str(ex)[:80]})", flush=True)
        try:
            running = any(r for _, r in gaudi_deployments())
        except Exception:
            running = True
        if gap >= BLIND_S and running and time.time() - tripped_at > 60:
            tripped_at = time.time()
            stop_all(f"blind for {gap:.0f} s")
    time.sleep(EVERY)
