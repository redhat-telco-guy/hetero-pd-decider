#!/usr/bin/env python3
"""kv-compat labeler: gives every vLLM model-server pod a KV compatibility key.

Two pods with the same key are configured identically in every way that decides whether
they can exchange KV over NIXL. The key is a short hash of:

  model        the model argument string exactly as passed (vLLM hashes this string)
  image        container image digest (pins the vLLM build, including vendor forks)
  version      vLLM version reported by GET /version
  backend      attention backend actually in use (from the startup log, or the explicit
               --attention-backend / VLLM_ATTENTION_BACKEND setting)
  kv_layout    KV layout settings: kv_buffer_device, enable_permute_local_kv, and any
               *KV_LAYOUT* environment variable (for example vllm-gaudi's hetero layout)
  connector    kv_connector named in --kv-transfer-config
  block_size, kv_dtype, dtype, tp, pp    from the arguments and vllm:cache_config_info

The accelerator model is deliberately not part of the key: two GPU generations with the
same settings (same backend, layout and build) get the same key, because that is what
the handshake checks. Different vendors normally differ in image, backend and layout, so
they get different keys and must be validated (61-validate-pair.sh) before they may pair.

If any input cannot be read (for example the backend line is not in the log yet), the pod
gets no key. In a mixed pool hetero-pd-decider treats a missing key as incompatible, so an
unreadable pod can never be paired by mistake.

The full inputs are written to the annotation llm-d.ai/kv-compat-inputs so anyone can see
why two pods did or did not match.

Approvals. For every prefill/decode pair whose keys differ, the labeler keeps a record in the
ConfigMap kv-compat-approvals (one entry per key pair, "<prefillKey>.to.<decodeKey>"):
  untested -> testing -> passed | failed | error
With AUTO_TEST on, it starts the validation Job (validate_pair.py) for each new pair, one at a
time, and stores the result. A person approves a passed pair (dashboard, console or
62-approve-pair.sh); only then does the labeler label the decode pods
accept.kv-compat.llm-d.ai/<prefillKey>=true, which hetero-pd-decider reads live. Revoking, a
failed re-test or a changed key removes the label within one cycle. A failed or untested pair
can never be approved.

Speed. Whenever a pod's key changes (a new pod, or new settings), the labeler measures that pod's
prefill speed once: a warm-up and SPEED_REPEATS uncached long prompts with max_tokens=1, sent
straight to the pod, keeping the second-best rate. The result goes on the pod as the label
llm-d.ai/prefill-tokens-per-sec, which hetero-pd-decider reads live in place of the class
profile. The key it was measured for is kept in the annotation llm-d.ai/prefill-tokens-per-sec-key;
the speed is not measured again until the key changes. While a pod is busy (more than
SPEED_MAX_RUNNING requests running) the measurement waits, so traffic doesn't skew it. A stale
speed label is removed as soon as the key changes, so the router falls back to the profile meanwhile.

Read-only towards the model servers, apart from those few measurement requests: it patches pod labels and annotations, the two ConfigMaps,
and creates validation Jobs.
"""
import hashlib, json, os, re, ssl, sys, threading, time, urllib.error, urllib.parse, urllib.request, uuid

NS = open("/var/run/secrets/kubernetes.io/serviceaccount/namespace").read().strip()
API = "https://kubernetes.default.svc"
CTX = ssl.create_default_context(cafile="/var/run/secrets/kubernetes.io/serviceaccount/ca.crt")
SELECTOR = os.environ.get("SELECTOR", "llm-d.ai/role")
LABEL = os.environ.get("LABEL", "llm-d.ai/kv-compat-key")
ANNOTATION = os.environ.get("ANNOTATION", "llm-d.ai/kv-compat-inputs")
RESTARTS_ANN = ANNOTATION + "-restarts"   # restart count of the container whose settings are saved
EVERY = int(os.environ.get("EVERY", "30"))
ACCEPT_PREFIX = os.environ.get("ACCEPT_PREFIX", "accept.kv-compat.llm-d.ai/")
APPROVALS_CM = os.environ.get("APPROVALS_CM", "kv-compat-approvals")
RESULTS_CM = os.environ.get("RESULTS_CM", "kv-compat-results")
AUTO_TEST = os.environ.get("AUTO_TEST", "true").lower() == "true"
TEST_PROMPTS = os.environ.get("TEST_PROMPTS", "20")
TEST_TIMEOUT = int(os.environ.get("TEST_TIMEOUT", "1800"))
VALIDATE_IMAGE = os.environ.get("VALIDATE_IMAGE", "registry.access.redhat.com/ubi9/python-311:latest")
MISSES_BEFORE_UNLABEL = 3
PREFILL_ROLES = {"prefill", "encode-prefill", "prefill-decode", "encode-prefill-decode"}
DECODE_ROLES = {"decode", "prefill-decode", "encode-prefill-decode"}
HUMAN_FIELDS = ("approved", "approvedBy", "approvedAt", "revokedBy", "revokedAt", "retest")
CONTAINER = os.environ.get("CONTAINER", "modelserver")
BACKEND_RE = re.compile(r"Using ([A-Za-z0-9_.]+)(?: attention)? backend", re.I)
INFO_RE = re.compile(r'^vllm:cache_config_info\{([^}]*)\}', re.M)
LABEL_RE = re.compile(r'(\w+)="([^"]*)"')
MEASURE_SPEED = os.environ.get("MEASURE_SPEED", "true").lower() == "true"
SPEED_LABEL = os.environ.get("SPEED_LABEL", "llm-d.ai/prefill-tokens-per-sec")
SPEED_KEY_ANN = SPEED_LABEL + "-key"
SPEED_WORDS = int(os.environ.get("SPEED_WORDS", "2500"))
SPEED_REPEATS = int(os.environ.get("SPEED_REPEATS", "5"))
SPEED_MAX_RUNNING = float(os.environ.get("SPEED_MAX_RUNNING", "1"))
RUNNING_RE = re.compile(r'^vllm:num_requests_running(?:\{[^}]*\})?\s+([0-9.eE+-]+)', re.M)
SPEED_WORDLIST = "service latency request cache region error timeout deploy gateway queue disk memory alert owner".split()
MEASURING = {"pod": None}


def tok():
    return open("/var/run/secrets/kubernetes.io/serviceaccount/token").read().strip()


def k8s(method, path, body=None, ctype="application/json", raw=False):
    req = urllib.request.Request(API + path, method=method,
                                 data=json.dumps(body).encode() if body is not None else None)
    req.add_header("Authorization", "Bearer " + tok())
    if body is not None:
        req.add_header("Content-Type", ctype)
    with urllib.request.urlopen(req, timeout=10, context=CTX) as r:
        data = r.read()
    return data.decode(errors="replace") if raw else json.loads(data)


def http_get(url):
    with urllib.request.urlopen(url, timeout=5) as r:
        return r.read().decode(errors="replace")


def arg_value(args, name):
    """Value of --name=value or --name value, else None."""
    for i, a in enumerate(args):
        if a == name and i + 1 < len(args):
            return args[i + 1]
        if a.startswith(name + "="):
            return a.split("=", 1)[1]
    return None


def model_arg(container):
    args = (container.get("command") or []) + (container.get("args") or [])
    m = arg_value(args, "--model")
    if m:
        return m
    if "serve" in args:  # vllm serve <model> ...
        i = args.index("serve")
        if i + 1 < len(args) and not args[i + 1].startswith("-"):
            return args[i + 1]
    return None


def inputs_for(pod):
    spec = pod["spec"]
    c = next((x for x in spec["containers"] if x["name"] == CONTAINER), None)
    if c is None:
        return None, "no container named " + CONTAINER
    args = (c.get("command") or []) + (c.get("args") or [])
    env = {e["name"]: e.get("value", "") for e in c.get("env", []) if "value" in e}
    port = next((p["containerPort"] for p in c.get("ports", []) if p.get("name") == CONTAINER), 8000)
    ip = pod["status"].get("podIP")
    status = next((s for s in pod["status"].get("containerStatuses", []) if s["name"] == CONTAINER), {})
    image = status.get("imageID") or c.get("image")

    kvt = arg_value(args, "--kv-transfer-config")
    kv = {}
    if kvt:
        try:
            kv = json.loads(kvt)
        except ValueError:
            return None, "unreadable --kv-transfer-config"

    try:
        version = json.loads(http_get(f"http://{ip}:{port}/version")).get("version")
    except Exception as ex:  # server not up yet
        return None, f"/version not readable: {ex}"
    info = {}
    try:
        m = INFO_RE.search(http_get(f"http://{ip}:{port}/metrics"))
        if m:
            info = dict(LABEL_RE.findall(m.group(1)))
    except Exception:
        pass

    backend = arg_value(args, "--attention-backend") or env.get("VLLM_ATTENTION_BACKEND")
    if not backend:
        try:
            log = k8s("GET", f"/api/v1/namespaces/{NS}/pods/{pod['metadata']['name']}/log?container={CONTAINER}&limitBytes=4000000", raw=True)
            found = BACKEND_RE.findall(log)
            backend = found[-1] if found else None
        except Exception:
            backend = None
    if not backend:
        return None, "attention backend not found in args, env or log"

    inputs = {
        "model": model_arg(c),
        "image": image,
        "version": version,
        "backend": backend.split(".")[-1].upper(),
        "connector": kv.get("kv_connector"),
        "kv_buffer_device": kv.get("kv_buffer_device"),
        "enable_permute_local_kv": bool(kv.get("enable_permute_local_kv", False)),
        "kv_layout_env": {k: v for k, v in sorted(env.items()) if "KV_LAYOUT" in k},
        "block_size": info.get("block_size") or arg_value(args, "--block-size"),
        "kv_dtype": info.get("cache_dtype") or arg_value(args, "--kv-cache-dtype") or "auto",
        "dtype": arg_value(args, "--dtype") or "auto",
        "tp": arg_value(args, "--tensor-parallel-size") or "1",
        "pp": arg_value(args, "--pipeline-parallel-size") or "1",
    }
    if not inputs["model"]:
        return None, "model argument not found"
    return inputs, None


def pod_hostport(pod):
    c = next((x for x in pod["spec"]["containers"] if x["name"] == CONTAINER), {})
    port = next((p["containerPort"] for p in c.get("ports", []) if p.get("name") == CONTAINER), 8000)
    return f"{pod['status']['podIP']}:{port}"


def busy(hp):
    try:
        return sum(float(v) for v in RUNNING_RE.findall(http_get(f"http://{hp}/metrics"))) > SPEED_MAX_RUNNING
    except Exception:
        return True


def prefill_rate(hp, model):
    """Prompt tokens per second for an uncached long prompt: second-best of SPEED_REPEATS runs."""
    import random
    rng = random.Random(3)
    prompt = " ".join(rng.choice(SPEED_WORDLIST) for _ in range(SPEED_WORDS))

    def call():
        body = {"model": model, "prompt": prompt, "max_tokens": 1, "temperature": 0, "cache_salt": uuid.uuid4().hex}
        req = urllib.request.Request(f"http://{hp}/v1/completions", data=json.dumps(body).encode(), method="POST",
                                     headers={"Content-Type": "application/json"})
        t0 = time.perf_counter()
        with urllib.request.urlopen(req, timeout=300) as r:
            n = json.loads(r.read())["usage"]["prompt_tokens"]
        return n / (time.perf_counter() - t0)
    call()  # warm-up
    runs = sorted(call() for _ in range(SPEED_REPEATS))
    return (runs[-2] if len(runs) > 1 else runs[0]), runs


def measure_speed(name, hp, model, key):
    try:
        rate, runs = prefill_rate(hp, model)
        k8s("PATCH", f"/api/v1/namespaces/{NS}/pods/{name}",
            {"metadata": {"labels": {SPEED_LABEL: str(int(round(rate)))},
                          "annotations": {SPEED_KEY_ANN: key, SPEED_LABEL + "-measured": now_iso()}}},
            "application/merge-patch+json")
        print(f"{name}: {SPEED_LABEL}={rate:.0f} for key {key} (runs {[round(r) for r in runs]})", flush=True)
    except Exception as ex:
        print(f"{name}: speed measurement failed, will retry: {ex}", flush=True)
    finally:
        MEASURING["pod"] = None


def check_speed(pod, key, inputs):
    """Measure a pod's prefill speed once per compatibility key; drop a speed measured for an older key."""
    if not MEASURE_SPEED:
        return
    name = pod["metadata"]["name"]
    labels, ann = pod["metadata"]["labels"], pod["metadata"].get("annotations", {}) or {}
    if ann.get(SPEED_KEY_ANN) == key and labels.get(SPEED_LABEL):
        return
    if labels.get(SPEED_LABEL):
        k8s("PATCH", f"/api/v1/namespaces/{NS}/pods/{name}", {"metadata": {"labels": {SPEED_LABEL: None}}},
            "application/merge-patch+json")
        labels.pop(SPEED_LABEL, None)
        print(f"{name}: key changed to {key}; old speed removed until it is measured again", flush=True)
    if MEASURING["pod"]:
        return
    hp = pod_hostport(pod)
    if busy(hp):
        return
    MEASURING["pod"] = name
    print(f"{name}: measuring prefill speed for key {key}", flush=True)
    threading.Thread(target=measure_speed, args=(name, hp, inputs["model"], key), daemon=True).start()


def key_of(inputs):
    digest = hashlib.sha256(json.dumps(inputs, sort_keys=True).encode()).hexdigest()
    return "kv-" + digest[:12]


def now_iso():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def pair_id(pk, dk):
    return f"{pk}.to.{dk}"


def get_cm(name):
    try:
        return k8s("GET", f"/api/v1/namespaces/{NS}/configmaps/{name}")
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return None
        raise


def load_records():
    cm = get_cm(APPROVALS_CM)
    if cm is None:
        k8s("POST", f"/api/v1/namespaces/{NS}/configmaps", {"metadata": {"name": APPROVALS_CM}, "data": {}})
        return {}
    out = {}
    for k, v in (cm.get("data") or {}).items():
        try:
            out[k] = json.loads(v)
        except ValueError:
            pass
    return out


def save_records(changed):
    """Write changed records, keeping approval fields a person may have set meanwhile."""
    if not changed:
        return
    fresh = load_records()
    data = {}
    for rid, rec in changed.items():
        base = fresh.get(rid) or {}
        for f in HUMAN_FIELDS:
            if f in base and rec.get("_owner") != "labeler-reset":
                rec[f] = base[f]
        rec.pop("_owner", None)
        data[rid] = json.dumps(rec, sort_keys=True)
    k8s("PATCH", f"/api/v1/namespaces/{NS}/configmaps/{APPROVALS_CM}", {"data": data}, "application/merge-patch+json")


def read_result(rid):
    cm = get_cm(RESULTS_CM)
    if not cm:
        return None
    raw = (cm.get("data") or {}).get(rid + ".json")
    try:
        return json.loads(raw) if raw else None
    except ValueError:
        return None


def start_test(rec, model):
    job = "kv-validate-" + uuid.uuid4().hex[:10]
    env = [{"name": "PREFILL", "value": rec["prefillPod"]}, {"name": "DECODE", "value": rec["decodePod"]},
           {"name": "MODEL", "value": model}, {"name": "PROMPTS", "value": TEST_PROMPTS},
           {"name": "RESULT_KEY", "value": rec["id"]}]
    k8s("POST", f"/apis/batch/v1/namespaces/{NS}/jobs", {
        "metadata": {"name": job, "labels": {"app": "kv-validate", "kv-compat-pair": rec["id"][:63]}},
        "spec": {"backoffLimit": 0, "ttlSecondsAfterFinished": 86400, "template": {
            "metadata": {"labels": {"app": "kv-validate"}},
            "spec": {"serviceAccountName": "kv-compat", "restartPolicy": "Never", "containers": [{
                "name": "validate", "image": VALIDATE_IMAGE, "command": ["python3", "-u", "/app/validate_pair.py"],
                "env": env, "volumeMounts": [{"name": "app", "mountPath": "/app"}]}],
                "volumes": [{"name": "app", "configMap": {"name": "kv-compat-scripts"}}]}}}})
    return job


def job_state(job):
    try:
        st = k8s("GET", f"/apis/batch/v1/namespaces/{NS}/jobs/{job}").get("status", {})
    except urllib.error.HTTPError as e:
        return "missing" if e.code == 404 else "unknown"
    if st.get("succeeded"):
        return "succeeded"
    if st.get("failed"):
        return "failed"
    return "running"


def apply_result(rec, res):
    rec["status"] = "passed" if res.get("verdict") == "PASS" else "failed"
    rec["testedAt"] = res.get("time", now_iso())
    rec["result"] = {k: res.get(k) for k in ("errors", "compared", "first_token_same", "split_agreement",
                                               "prefill_alone_agreement", "checks", "prefill", "decode")}
    if rec["status"] != "passed" and rec.get("approved"):
        rec["approved"], rec["revokedBy"], rec["revokedAt"] = False, "failed re-test", now_iso()
        rec["_owner"] = "labeler-reset"


def manage_pairs(keyed):
    """keyed: list of (pod, key, inputs). Returns {decodeKey: set(approved prefillKeys)}."""
    records = load_records()
    changed = {}
    prefill = [(p, k, i) for p, k, i in keyed if p["metadata"]["labels"].get("llm-d.ai/role") in PREFILL_ROLES]
    decode = [(p, k, i) for p, k, i in keyed if p["metadata"]["labels"].get("llm-d.ai/role") in DECODE_ROLES]
    live = {}
    for pp, pk, pin in prefill:
        for dp, dk, _ in decode:
            if pk == dk or pp["metadata"]["name"] == dp["metadata"]["name"]:
                continue
            rid = pair_id(pk, dk)
            live[rid] = (pp, dp, pin)
            rec = records.get(rid)
            if rec is None:
                rec = {"id": rid, "prefillKey": pk, "decodeKey": dk, "status": "untested", "approved": False,
                       "firstSeen": now_iso()}
                records[rid] = rec
                changed[rid] = rec
                print(f"new pair {rid}: {pp['metadata']['name']} -> {dp['metadata']['name']}", flush=True)
            names = (pp["metadata"]["name"], dp["metadata"]["name"])
            if (rec.get("prefillPod"), rec.get("decodePod")) != names:
                rec["prefillPod"], rec["decodePod"] = names
                rec["prefillClass"] = pp["metadata"]["labels"].get("llm-d.ai/accelerator-class", "")
                rec["decodeClass"] = dp["metadata"]["labels"].get("llm-d.ai/accelerator-class", "")
                changed[rid] = rec
    for rid, rec in records.items():
        # A person asked for a re-test: start over; approval must be given again after it.
        if rec.get("retest"):
            rec.update(status="untested", retest=False, approved=False, _owner="labeler-reset")
            rec.pop("job", None)
            changed[rid] = rec
        if rec.get("status") == "testing":
            state = job_state(rec.get("job", ""))
            res = read_result(rid)
            if res and res.get("time", "") >= rec.get("testStarted", ""):
                apply_result(rec, res)
                changed[rid] = rec
                print(f"pair {rid}: test {rec['status']}", flush=True)
            elif state in ("failed", "missing") or time.time() - rec.get("testStartedEpoch", 0) > TEST_TIMEOUT:
                rec["status"], rec["testedAt"] = "error", now_iso()
                rec["result"] = {"note": f"validation job {state} without a result; see: oc logs job/{rec.get('job')}"}
                changed[rid] = rec
        elif rec.get("status") in ("untested", "failed", "error", "passed"):
            # A manual run of 61-validate-pair.sh newer than what we have.
            res = read_result(rid)
            if res and res.get("time", "") > rec.get("testedAt", ""):
                apply_result(rec, res)
                changed[rid] = rec
    if AUTO_TEST and not any(r.get("status") == "testing" for r in records.values()):
        for rid, rec in sorted(records.items()):
            if rec.get("status") == "untested" and rid in live:
                pp, dp, pin = live[rid]
                try:
                    rec["job"] = start_test(rec, pin["model"])
                    rec["status"], rec["testStarted"], rec["testStartedEpoch"] = "testing", now_iso(), time.time()
                    changed[rid] = rec
                    print(f"pair {rid}: started {rec['job']}", flush=True)
                except Exception as ex:
                    print(f"pair {rid}: cannot start the test: {ex}", flush=True)
                break
    save_records(changed)
    accepted = {}
    for rec in load_records().values():
        if rec.get("approved") and rec.get("status") == "passed":
            accepted.setdefault(rec["decodeKey"], set()).add(rec["prefillKey"])
    return accepted


def apply_accept_labels(decode_pods, accepted):
    for pod, key in decode_pods:
        labels = pod["metadata"].get("labels", {})
        want = accepted.get(key, set())
        have = {k[len(ACCEPT_PREFIX):] for k, v in labels.items() if k.startswith(ACCEPT_PREFIX) and v == "true"}
        stale = {k[len(ACCEPT_PREFIX):] for k in labels if k.startswith(ACCEPT_PREFIX)} - want
        patch = {ACCEPT_PREFIX + k: "true" for k in want - have}
        patch.update({ACCEPT_PREFIX + k: None for k in stale})
        if patch:
            k8s("PATCH", f"/api/v1/namespaces/{NS}/pods/{pod['metadata']['name']}",
                {"metadata": {"labels": patch}}, "application/merge-patch+json")
            print(f"{pod['metadata']['name']}: accepts {sorted(want) or 'none'}", flush=True)


def main():
    print(f"kv-compat labeler: namespace {NS}, selector {SELECTOR}, label {LABEL}, every {EVERY}s, "
          f"auto-test {'on' if AUTO_TEST else 'off'}", flush=True)
    seen, misses, known = {}, {}, {}
    while True:
        try:
            pods = k8s("GET", f"/api/v1/namespaces/{NS}/pods?labelSelector={urllib.parse.quote(SELECTOR)}")["items"]
        except Exception as ex:
            print(f"list pods failed: {ex}", flush=True)
            time.sleep(EVERY)
            continue
        keyed, decode_pods = [], []
        for pod in pods:
            name = pod["metadata"]["name"]
            if pod["status"].get("phase") != "Running" or not pod["status"].get("podIP"):
                continue
            pod["metadata"].setdefault("labels", {})
            inputs, why = inputs_for(pod)
            # A running container keeps the settings it started with. If they can't be read right now
            # (server busy, log read timed out), reuse what this same container reported before, so a
            # loaded server doesn't lose its key. A restart or a new pod is read fresh.
            ck = (pod["metadata"].get("uid"), sum(cs.get("restartCount", 0) for cs in pod["status"].get("containerStatuses", [])))
            if inputs is None and ck in known:
                inputs, why = known[ck], None
            if inputs is None:
                # Survives a labeler restart and log rotation: the settings saved on the pod itself,
                # used only while the container is the one that reported them (same restart count).
                ann = pod["metadata"].get("annotations", {}) or {}
                if ann.get(ANNOTATION) and ann.get(RESTARTS_ANN, "0") == str(ck[1]):
                    try:
                        inputs, why = json.loads(ann[ANNOTATION]), None
                    except ValueError:
                        pass
            if inputs is not None:
                known[ck] = inputs
            labels = pod["metadata"]["labels"]
            if inputs is None:
                misses[name] = misses.get(name, 0) + 1
                if seen.get(name) != why:
                    print(f"{name}: no key yet ({why})", flush=True)
                    seen[name] = why
                # Inputs unreadable several cycles in a row: remove a stale key and its approvals.
                if misses[name] >= MISSES_BEFORE_UNLABEL and (LABEL in labels or any(k.startswith(ACCEPT_PREFIX) for k in labels)):
                    rm = {k: None for k in labels if k == LABEL or k.startswith(ACCEPT_PREFIX)}
                    k8s("PATCH", f"/api/v1/namespaces/{NS}/pods/{name}", {"metadata": {"labels": rm}},
                        "application/merge-patch+json")
                continue
            misses[name] = 0
            key = key_of(inputs)
            if labels.get(LABEL) != key:
                k8s("PATCH", f"/api/v1/namespaces/{NS}/pods/{name}",
                    {"metadata": {"labels": {LABEL: key},
                                  "annotations": {ANNOTATION: json.dumps(inputs, sort_keys=True), RESTARTS_ANN: str(ck[1])}}},
                    "application/merge-patch+json")
                print(f"{name}: {LABEL}={key}  {json.dumps(inputs, sort_keys=True)}", flush=True)
                labels[LABEL] = key
            seen[name] = key
            try:
                check_speed(pod, key, inputs)
            except Exception as ex:
                print(f"{name}: speed check failed: {ex}", flush=True)
            keyed.append((pod, key, inputs))
            if labels.get("llm-d.ai/role") in DECODE_ROLES:
                decode_pods.append((pod, key))
        try:
            apply_accept_labels(decode_pods, manage_pairs(keyed))
        except Exception as ex:
            print(f"approvals cycle failed: {ex}", flush=True)
        time.sleep(EVERY)


if __name__ == "__main__":
    sys.exit(main())
