"""Gaudi thermal test that runs inside the cluster as a Job, so a laptop disconnect cannot stall it.

Phases (each printed as 'phase,<UTC time>,<name>'): idle 1 min, warm-up of a Gaudi model server on each
card, chat load in steps (STEPS users, STEP_MIN minutes each), cool-down 3 min with the servers stopped.
The gaudi-watchdog pod records temperatures and stops the Gaudis at its limit; this job notices and ends.
"""
import json, os, ssl, time, urllib.request

NS = os.environ.get("NS", "hetero-pd-lab")
DEP = os.environ.get("DEPLOYMENT", "decode-gaudi3")
STEPS = [int(x) for x in os.environ.get("STEPS", "2 4 8 16").split()]
STEP_MIN = float(os.environ.get("STEP_MIN", "3"))
REPLICAS = int(os.environ.get("REPLICAS", "2"))
DASH = f"http://hetero-pd-dashboard.{NS}.svc:8080"
API = "https://kubernetes.default.svc"
CTX = ssl.create_default_context(cafile="/var/run/secrets/kubernetes.io/serviceaccount/ca.crt")


def k8s(method, path, body=None, ctype="application/merge-patch+json"):
    req = urllib.request.Request(API + path, method=method, data=json.dumps(body).encode() if body is not None else None)
    req.add_header("Authorization", "Bearer " + open("/var/run/secrets/kubernetes.io/serviceaccount/token").read().strip())
    if body is not None:
        req.add_header("Content-Type", ctype)
    return json.loads(urllib.request.urlopen(req, context=CTX, timeout=10).read() or b"{}")


def dash(path, body=None):
    req = urllib.request.Request(DASH + path, data=json.dumps(body).encode() if body is not None else None,
                                 headers={"Content-Type": "application/json"})
    return json.loads(urllib.request.urlopen(req, timeout=15).read() or b"{}")


def phase(name):
    print(f"phase,{time.strftime('%H:%M:%S', time.gmtime())},{name}", flush=True)


def dep():
    d = k8s("GET", f"/apis/apps/v1/namespaces/{NS}/deployments/{DEP}")
    return d["spec"].get("replicas", 0), d["status"].get("readyReplicas", 0) or 0


def scale(n):
    k8s("PATCH", f"/apis/apps/v1/namespaces/{NS}/deployments/{DEP}/scale", {"spec": {"replicas": n}})


def say(msg):
    print(f"{time.strftime('%H:%M:%S', time.gmtime())} {msg}", flush=True)


phase("idle"); time.sleep(60)
phase("warmup"); scale(REPLICAS)
t0 = time.time()
while True:
    want, ready = dep()
    if want == 0:
        say("the watchdog stopped the Gaudis during warm-up"); break
    if ready >= REPLICAS:
        say(f"{ready} Gaudi model servers ready after {(time.time() - t0) / 60:.1f} min"); break
    if time.time() - t0 > 40 * 60:
        say("warm-up did not finish in 40 min"); break
    time.sleep(20)

if dep()[0] > 0 and dep()[1] >= 1:
    for users in STEPS:
        if dep()[0] == 0:
            say("the watchdog stopped the Gaudis"); break
        phase(f"load-{users}-users")
        try:
            dash("/api/traffic/start", {"users": users, "docsPerSec": 0, "minutes": int(STEP_MIN), "chatTokens": 250, "docTokens": 700})
        except Exception as ex:
            say(f"could not start traffic: {ex}")
        end = time.time() + STEP_MIN * 60 + 5
        while time.time() < end:
            if dep()[0] == 0:
                break
            time.sleep(5)
        try:
            t = dash("/api/state").get("trafficTotal") or {}
            say(f"step {users} users: {t.get('chatDone')} replies, {t.get('errors')} errors, {round(t.get('tokensPerSec') or 0)} tok/s, chat first word p95 {t.get('chatTtftP95')}")
        except Exception as ex:
            say(f"no traffic summary: {ex}")
        if dep()[0] == 0:
            say(f"the watchdog stopped the Gaudis during the {users}-user step"); break
        time.sleep(15)
try:
    dash("/api/traffic/stop", {})
except Exception:
    pass
scale(0); phase("cooldown"); time.sleep(180); phase("end")
say("thermal test finished")
