#!/usr/bin/env bash
# Card-pair approvals from the command line (same record the dashboard uses).
#   bash lab/compat/62-approve-pair.sh list
#   bash lab/compat/62-approve-pair.sh approve <pair id>     # only a pair whose test PASSED
#   bash lab/compat/62-approve-pair.sh revoke  <pair id>
#   bash lab/compat/62-approve-pair.sh retest  <pair id>     # runs the test again; approve again after
# Pair ids look like kv-1a2b3c4d5e6f.to.kv-6f5e4d3c2b1a (prefill key .to. decode key).
# The labeler applies a change within about 30 seconds; the router needs no restart.
set -uo pipefail
NS=${NS:-hetero-pd-lab}; CM=kv-compat-approvals; ACTION=${1:-list}; ID=${2:-}
oc whoami >/dev/null 2>&1 || { echo "Not logged in. Run oc login first."; exit 1; }
WHO=$(oc whoami)
oc get configmap $CM -n $NS -o json 2>/dev/null > /tmp/kvc.$$ || { echo "No $CM in $NS yet: install lab/compat/60-compat-install.sh"; exit 1; }
NS=$NS python3 - "$ACTION" "$ID" "$WHO" /tmp/kvc.$$ <<'PY' > /tmp/kvc-patch.$$
import json, sys, time
action, rid, who, path = sys.argv[1:5]
recs = {k: json.loads(v) for k, v in (json.load(open(path)).get("data") or {}).items()}
if action == "list":
    print(f"{'PAIR':45} {'CARDS':28} {'TEST':9} APPROVED", file=sys.stderr)
    for k, r in sorted(recs.items()):
        cards = f"{r.get('prefillClass','?')} -> {r.get('decodeClass','?')}"
        print(f"{k:45} {cards:28} {r.get('status','?'):9} {'yes' if r.get('approved') else 'no'}", file=sys.stderr)
    sys.exit(0)
if rid not in recs:
    sys.exit(f"unknown pair {rid!r}; run: list")
r = recs[rid]
now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
if action == "approve":
    if r.get("status") != "passed":
        sys.exit(f"cannot approve: the test result is {r.get('status')!r}, not 'passed'")
    r.update(approved=True, approvedBy=who, approvedAt=now)
elif action == "revoke":
    r.update(approved=False, revokedBy=who, revokedAt=now)
elif action == "retest":
    r.update(retest=True)
else:
    sys.exit("action must be list, approve, revoke or retest")
print(json.dumps({"data": {rid: json.dumps(r, sort_keys=True)}}))
PY
rc=$?; rm -f /tmp/kvc.$$
[ $rc -ne 0 ] && { rm -f /tmp/kvc-patch.$$; exit $rc; }
[ "$ACTION" = list ] && { rm -f /tmp/kvc-patch.$$; exit 0; }
oc patch configmap $CM -n $NS --type merge --patch-file /tmp/kvc-patch.$$ >/dev/null && echo "$ACTION: $ID (applies within about 30 seconds)"
rm -f /tmp/kvc-patch.$$
