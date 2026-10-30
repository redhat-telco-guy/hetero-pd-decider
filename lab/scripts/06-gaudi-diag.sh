#!/usr/bin/env bash
# Why does worker2 advertise 1 Gaudi instead of 2? Inspect, restart device plugin, re-check.
set -uo pipefail
W2=worker2.ai154.dl154.dfw.ocp.run; HNS=habana-ai-operator
hr() { printf '\n==== %s ====\n' "$1"; }
oc whoami >/dev/null 2>&1 || { echo "Cannot reach cluster; reconnect and oc login, then re-run."; exit 1; }

hr "hl-smi on worker2"
DRV=$(oc get pods -n $HNS -o name | grep driver | head -1)
oc exec -n $HNS $DRV -- sh -c 'command -v hl-smi >/dev/null && hl-smi || (chroot /host hl-smi 2>/dev/null || echo "hl-smi not found in driver pod")' 2>&1 | head -40
oc debug node/$W2 -q -- chroot /host sh -c 'ls -l /dev/accel/ 2>/dev/null; ls /dev/hl* 2>/dev/null; dmesg | grep -iE "habanalabs.*(error|fail|timeout|disabled)" | tail -15' 2>&1

hr "Device plugin log (before restart)"
DP=$(oc get pods -n $HNS -o name | grep device-plugin | head -1)
oc logs -n $HNS $DP --tail=60 2>&1

hr "Node capacity vs allocatable"
oc get node $W2 -o jsonpath='capacity={.status.capacity.habana\.ai/gaudi} allocatable={.status.allocatable.habana\.ai/gaudi}{"\n"}'

hr "Restart device plugin"
oc delete -n $HNS $DP --wait=true
for i in $(seq 1 16); do
  hb=$(oc get node $W2 -o jsonpath='{.status.allocatable.habana\.ai/gaudi}')
  echo "[$i] Gaudi allocatable=${hb:-0}"; [ "${hb:-0}" -ge 2 ] && break; sleep 15
done

hr "Device plugin log (after restart)"
DP=$(oc get pods -n $HNS -o name | grep device-plugin | head -1)
oc logs -n $HNS $DP --tail=40 2>&1
