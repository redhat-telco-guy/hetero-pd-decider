#!/usr/bin/env bash
# Is the test suite healthy? Progress, finished runs (errors!), live traffic, router decisions, keys.
#   bash lab/aws-nvidia/73-suite-status.sh 2>&1 | tee suite-status.txt
NS=${NS:-hetero-pd-aws}
oc whoami >/dev/null 2>&1 || { echo "Not logged in. Run oc login first."; exit 1; }
echo "==== Keys and measured prefill speed (tokens/s; <none> = not measured yet)"
oc get pods -n $NS -l llm-d.ai/role --no-headers -o custom-columns='POD:.metadata.name,KEY:.metadata.labels.llm-d\.ai/kv-compat-key,SPEED:.metadata.labels.llm-d\.ai/prefill-tokens-per-sec' | sed 's/^/  /'
oc exec -i -n $NS deploy/hetero-pd-dashboard -- python3 - <<'PY'
import json, time, urllib.request
j = json.load(urllib.request.urlopen("http://localhost:8080/api/state"))
now = time.time(); s = j.get("suite") or {}; m = j.get("mode") or {}; cur = s.get("current") or {}
f = lambda v, d=2: "-" if v is None else "%.*f" % (d, v)
print("\n==== Router: %s | ready: %s | model sent: %s" % (m.get("current"), m.get("ready"), j.get("model")))
line = "==== Suite: " + ("RUNNING" if s.get("running") else "not running")
if s.get("total"): line += " | %s of %s runs done" % (s.get("done", 0), s["total"])
if cur: line += " | now: %s / %s / repeat %s" % (cur.get("name"), cur.get("mode"), cur.get("repeat"))
if s.get("started"): line += " | started %d min ago" % ((now - s["started"]) / 60)
print(line)
if s.get("error"): print("  SUITE ERROR:", s["error"])
t = j.get("trafficTotal")
if t and t.get("running"):
    print("\n==== Current run so far: %d chat replies, %d documents, %d errors, moved %.0f / kept %.0f"
          % (t["chatDone"], t["docDone"], t["errors"], t["moved"], t["kept"]))
    if t.get("lastError"): print("  last error:", str(t["lastError"])[:200])
print("\n==== Finished runs (newest first)")
print("  %-7s %-13s %6s %5s %7s %6s %7s %13s %12s" % ("mode", "scenario", "chat", "docs", "errors", "moved", "tok/s", "chat TTFT p95", "doc TTFT p50"))
for r in (j.get("history") or [])[:24]:
    flag = "   <-- ALL FAILED" if r["errors"] and not (r["chatDone"] or r["docDone"]) else ("   <-- some errors" if r["errors"] else "")
    print("  %-7s %-13s %6d %5d %7d %6.0f %7s %13s %12s%s" % (r["mode"] or "?", r.get("scenario") or "manual", r["chatDone"], r["docDone"],
          r["errors"], r["moved"], f(r["tokensPerSec"], 0), f(r["chatTtftP95"]), f(r["docTtftP50"]), flag))
    if r["errors"] and r.get("lastError"): print("      last error:", str(r["lastError"])[:160])
lv = j.get("live") or {}
print("\n==== Cards now (running / waiting / KV memory)")
for p in lv.get("pods", []):
    print("  %-12s %-8s %-4s %.0f / %.0f / %.0f%%" % (p["cls"], p["role"], "up" if p["up"] else "DOWN", p["running"], p["waiting"], p["kv"] * 100))
d = lv.get("dec") or {}
print("\n==== Router decisions since it started: moved %s | kept %s" % (f(d.get("moved"), 0), f(d.get("kept"), 0)))
for k, v in sorted((d.get("reasons") or {}).items(), key=lambda x: -x[1]):
    print("  %-28s %.0f" % (k, v))
PY
echo; printf "==== Handoffs the L4 refused (hash mismatch, current L4 log): "
oc logs -n $NS deploy/decode-l4 -c modelserver 2>/dev/null | grep -c 'compatibility hash mismatch'
