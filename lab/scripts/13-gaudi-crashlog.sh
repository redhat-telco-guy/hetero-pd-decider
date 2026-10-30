#!/usr/bin/env bash
# Capture why the Gaudi engine exited (previous container run), plus card and memory state.
NS=hetero-pd-lab
P=$(oc get pods -n $NS -l app=decode-gaudi3 --sort-by=.metadata.creationTimestamp -o name | tail -1)
echo "pod: $P"
oc get $P -n $NS -o jsonpath='{range .status.containerStatuses[*]}{.name}: restarts={.restartCount} last={.lastState.terminated.reason} exit={.lastState.terminated.exitCode}{"\n"}{end}'
echo "==== errors in previous run ===="
oc logs $P -n $NS -c modelserver --previous 2>&1 | grep -nE 'Error|error|Traceback|raise|Exception|RuntimeError|ValueError|Killed|OOM|synStatus|habana' | grep -v 'All plugins' | head -40 | cut -c1-300
echo "==== memory sizing (previous run) ===="
oc logs $P -n $NS -c modelserver --previous 2>&1 | grep -iE "free device memory|usable|KV cache|graph|bucket|memory" | grep -v WARNING | tail -15 | cut -c1-250
echo "==== last 60 lines of previous run ===="
oc logs $P -n $NS -c modelserver --previous --tail=60 2>&1 | grep -vE '^\s*\^+\s*$' | cut -c1-300
echo "==== current run (last 10) ===="
oc logs $P -n $NS -c modelserver --tail=10 2>&1 | cut -c1-250
