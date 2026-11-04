#!/usr/bin/env bash
# Pull the evidence behind the AWS results out of the cluster into evidence/aws-<date>/ and zip it,
# ready to attach to a GitHub comment. Reads only; no tokens, secrets or kubeconfig are written.
#   bash lab/aws-nvidia/76-export-evidence.sh
NS=${NS:-hetero-pd-aws}; REPO=$(cd "$(dirname "$0")/../.." && pwd)
oc whoami >/dev/null 2>&1 || { echo "Not logged in. Run oc login first."; exit 1; }
OUT=$REPO/evidence/aws-$(date +%Y-%m-%d); mkdir -p $OUT; cd $OUT
echo "Writing to $OUT"

# 1. Every test run the dashboard recorded (raw), then a CSV and a per-suite summary of medians.
oc get configmap hetero-pd-dashboard-results -n $NS -o jsonpath='{.data.history\.json}' > runs-raw.json
python3 - <<'PY'
import csv, json, statistics, time
runs = json.load(open("runs-raw.json"))
# Leave out runs from before the dashboard fix, where every request failed (wrong model name).
good = [r for r in runs if r.get("suite") and (r.get("chatDone") or r.get("docDone"))]
cols = ["suiteStarted", "mode", "scenario", "users", "docsPerSec", "chatTokens", "docTokens", "chatDone", "docDone",
        "errors", "lastError", "moved", "kept", "tokensPerSec", "chatTtftP50", "chatTtftP95", "chatItlP95", "docTtftP50", "docTtftP95", "startedAt"]
fmt = lambda t: time.strftime("%Y-%m-%d %H:%M UTC", time.gmtime(t))
with open("runs.csv", "w", newline="") as f:
    w = csv.writer(f); w.writerow(cols)
    for r in sorted(good, key=lambda r: r["startedAt"]):
        w.writerow([fmt(r["suite"]) if c == "suiteStarted" else fmt(r[c]) if c == "startedAt" else r.get(c) for c in cols])
names = {"busy-chat": "Busy chat", "busy-medium": "Busy + 700-token docs", "busy-long": "Busy + 2,000-token docs",
         "idle-long": "Idle + 2,000-token docs", "busy-huge": "Busy + 6,000-token reports", "light-chat": "Light chat"}
med = lambda xs: statistics.median(xs) if xs else None
ms = lambda v: "-" if v is None else f"{v*1000:.0f} ms"
lines = ["# Results summary", "",
         "Medians across repeats, generated from runs-raw.json. Only complete test suites are summarised;",
         "'Failed requests' lists each run separately. Doc first token = time until a document's first answer token.", ""]
allsuites = sorted({r["suite"] for r in good})
complete = [s for s in allsuites if sum(r["suite"] == s for r in good) >= 24]
titles = ["Test 1: each card's default attention backend (T4 TRITON_ATTN, A10G and L4 FLASH_ATTN)",
          "Test 2: --attention-backend TRITON_ATTN on all three cards"]
for i, s in enumerate(complete):
    rs = [r for r in good if r["suite"] == s]
    lines += [f"## {titles[i] if i < len(titles) else 'Suite ' + str(i + 1)}", "",
              f"Started {fmt(s)}, {len(rs)} runs (3 repeats, stock and plugin alternated).", "",
              "| Scenario | Mode | Runs | Failed requests (each run) | Docs done | Doc first token | Chat first token p95 | Output tok/s |",
              "|---|---|---|---|---|---|---|---|"]
    for sc in names:
        for mode in ("stock", "auto"):
            x = [r for r in rs if r.get("scenario") == sc and r["mode"] == mode]
            if not x:
                continue
            lines.append(f"| {names[sc]} | {'llm-d default' if mode == 'stock' else 'with plugin'} | {len(x)} | "
                         f"{', '.join(str(r['errors']) for r in x)} | {', '.join(str(r['docDone']) for r in x)} | "
                         f"{ms(med([r['docTtftP50'] for r in x if r.get('docTtftP50') is not None]))} | "
                         f"{ms(med([r['chatTtftP95'] for r in x if r.get('chatTtftP95') is not None]))} | "
                         f"{med([r['tokensPerSec'] for r in x]):.0f} |")
    lines.append("")
other = [s for s in allsuites if s not in complete]
if other:
    lines += ["## Not counted", "", "Partial suites, kept in runs.csv: quick check runs, a suite stopped when the decode",
              "server ran out of memory (its limit was raised afterwards), and a restarted suite.", ""]
    lines += [f"- started {fmt(s)}: {sum(r['suite'] == s for r in good)} runs" for s in other] + [""]
open("results-summary.md", "w").write("\n".join(lines))
print(f"  runs: {len(runs)} recorded, {len(good)} valid, {len(complete)} complete suites")
PY

# 2. Compatibility keys, the settings behind each key, measured speeds, and pod versions.
oc get pods -n $NS -l llm-d.ai/role -o json | python3 -c '
import json, sys
out = []
for p in json.load(sys.stdin)["items"]:
    m = p["metadata"]; a = m.get("annotations", {}); l = m.get("labels", {})
    c = next(c for c in p["spec"]["containers"] if c["name"] == "modelserver")
    out.append({"pod": m["name"], "role": l.get("llm-d.ai/role"), "card": l.get("llm-d.ai/accelerator-class"),
                "node": p["spec"].get("nodeName"), "compatKey": l.get("llm-d.ai/kv-compat-key"),
                "keyInputs": json.loads(a.get("llm-d.ai/kv-compat-inputs", "{}")),
                "measuredPrefillTokensPerSec": l.get("llm-d.ai/prefill-tokens-per-sec"),
                "speedMeasuredAt": a.get("llm-d.ai/prefill-tokens-per-sec-measured"),
                "image": c.get("image"), "args": c.get("args")})
json.dump(out, open("pods-keys-and-speeds.json", "w"), indent=2)' && echo "  pods-keys-and-speeds.json"

# 3. Pair test results and approvals (includes the T4 -> L4 test from the default-backend run).
for cm in kv-compat-approvals kv-compat-results; do
  oc get configmap $cm -n $NS -o json 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin).get("data") or {}; print(json.dumps({k:(json.loads(v) if v[:1] in "{[" else v) for k,v in d.items()}, indent=2))' > $cm.json && echo "  $cm.json"
done

# 4. Handshake rejections on the decode server, if its current log still has them, plus the labeler log.
oc logs -n $NS deploy/decode-l4 -c modelserver 2>/dev/null | grep -E 'compatibility hash mismatch|handshake_failed' | head -20 > decode-l4-handshake-errors.log
echo "  decode-l4-handshake-errors.log: $(wc -l < decode-l4-handshake-errors.log | tr -d ' ') lines (current pod log only)"
oc logs -n $NS deploy/kv-compat-labeler --tail=300 > labeler.log 2>&1

# 5. Router configs used (stock and plugin) and the cluster/GPU inventory.
cp $REPO/lab/aws-nvidia/modes.values.aws.yaml router-configs.yaml
{ oc version 2>/dev/null | grep -v -i token; echo; oc get nodes -L nvidia.com/gpu.product,node.kubernetes.io/instance-type,nvidia.com/cuda.driver-version.full --no-headers -l nvidia.com/gpu.present=true; } > cluster.txt
oc get deploy -n $NS -o custom-columns='DEPLOY:.metadata.name,IMAGE:.spec.template.spec.containers[*].image' > images.txt

cat > README.md <<MD
# Evidence: hetero-pd-decider on AWS (T4 + A10G prefill, L4 decode)

| File | What it shows |
|---|---|
| results-summary.md | Per suite and scenario: failed requests per run, documents completed, median first-token times |
| runs.csv / runs-raw.json | Every recorded run, as recorded by the test dashboard |
| pods-keys-and-speeds.json | Each model server's compatibility key, the settings behind it, and its measured prefill speed |
| kv-compat-approvals.json / kv-compat-results.json | Pair test results (validation job) and approvals |
| decode-l4-handshake-errors.log | "NIXL compatibility hash mismatch" lines from the decode server (current pod only) |
| decode-l4-handshake-errors-default-backends.log | The same errors captured during the default-backend run (T4 to L4 handoffs rejected) |
| router-configs.yaml | The router configurations compared: stock prefix-based-pd-decider and hetero-pd-decider |
| cluster.txt, images.txt | OpenShift/Kubernetes versions, GPU nodes, container images |
| labeler.log | The labeler's recent decisions (keys, tests, speed measurements) |

Suites: the earlier one ran with each card's default attention backend (T4: TRITON_ATTN, A10G/L4: FLASH_ATTN);
the later one with --attention-backend TRITON_ATTN on all three. Runs from before a dashboard fix, where every
request failed because of a wrong model name, are left out of the summary and CSV but kept in runs-raw.json.
MD
cd ..; rm -f aws-$(date +%Y-%m-%d).zip; zip -qr aws-$(date +%Y-%m-%d).zip aws-$(date +%Y-%m-%d) && echo "Zip: $REPO/evidence/aws-$(date +%Y-%m-%d).zip"
