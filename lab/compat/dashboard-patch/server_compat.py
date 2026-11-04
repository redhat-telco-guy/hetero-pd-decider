
# ---------------- card compatibility (Stack tab): keys, tested pairs, approvals ----------------
APPROVALS_CM = "kv-compat-approvals"
COMPAT_LABEL = "llm-d.ai/kv-compat-key"
ACCEPT_PREFIX = "accept.kv-compat.llm-d.ai/"
PREFILL_ROLES = {"prefill", "encode-prefill", "prefill-decode", "encode-prefill-decode"}
DECODE_ROLES = {"decode", "prefill-decode", "encode-prefill-decode"}


def compat_state():
    pods = []
    for p in k8s("GET", f"/api/v1/namespaces/{NS}/pods?labelSelector={urllib.parse.quote('llm-d.ai/role')}")["items"]:
        lab = p["metadata"].get("labels", {})
        ann = p["metadata"].get("annotations", {}) or {}
        try:
            inputs = json.loads(ann.get("llm-d.ai/kv-compat-inputs", "") or "null")
        except ValueError:
            inputs = None
        pods.append({"name": p["metadata"]["name"], "role": lab.get("llm-d.ai/role", ""),
                     "cls": lab.get("llm-d.ai/accelerator-class", ""), "key": lab.get(COMPAT_LABEL, ""),
                     "accepts": sorted(k[len(ACCEPT_PREFIX):] for k, v in lab.items() if k.startswith(ACCEPT_PREFIX) and v == "true"),
                     "inputs": inputs, "running": p["status"].get("phase") == "Running"})
    try:
        cm = k8s("GET", f"/api/v1/namespaces/{NS}/configmaps/{APPROVALS_CM}")
        records = []
        for v in (cm.get("data") or {}).values():
            try:
                records.append(json.loads(v))
            except ValueError:
                pass
        installed = True
    except urllib.error.HTTPError as e:
        if e.code != 404:
            raise
        records, installed = [], False
    same = [{"prefill": a["name"], "decode": b["name"], "prefillClass": a["cls"], "decodeClass": b["cls"], "key": a["key"]}
            for a in pods for b in pods
            if a["role"] in PREFILL_ROLES and b["role"] in DECODE_ROLES and a["name"] != b["name"] and a["key"] and a["key"] == b["key"]]
    live_keys = {p["key"] for p in pods if p["key"]}
    for r in records:
        r["live"] = r.get("prefillKey") in live_keys and r.get("decodeKey") in live_keys
    records.sort(key=lambda r: (not r["live"], r.get("id", "")))
    return {"installed": installed, "pods": pods, "pairs": records, "sameKey": same}


def compat_update(rid, action, who):
    cm = k8s("GET", f"/api/v1/namespaces/{NS}/configmaps/{APPROVALS_CM}")
    raw = (cm.get("data") or {}).get(rid)
    if not raw:
        raise ValueError("unknown pair")
    rec = json.loads(raw)
    now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    if action == "approve":
        if rec.get("status") != "passed":
            raise PermissionError(f"Only a pair whose test passed can be approved (this one: {rec.get('status')}).")
        rec.update(approved=True, approvedBy=who, approvedAt=now)
    elif action == "revoke":
        rec.update(approved=False, revokedBy=who, revokedAt=now)
    elif action == "retest":
        if rec.get("status") == "testing":
            raise PermissionError("A test of this pair is already running.")
        rec.update(retest=True)
    else:
        raise ValueError("unknown action")
    k8s("PATCH", f"/api/v1/namespaces/{NS}/configmaps/{APPROVALS_CM}",
        {"data": {rid: json.dumps(rec, sort_keys=True)}}, "application/merge-patch+json")
