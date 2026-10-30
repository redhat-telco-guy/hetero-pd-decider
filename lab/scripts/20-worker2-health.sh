#!/usr/bin/env bash
# Read-only: did worker2 reboot, and is the remaining Gaudi card healthy?
W2=worker2.ai154.dl154.dfw.ocp.run; HNS=habana-ai-operator
hr() { printf '\n==== %s ====\n' "$1"; }
hr "Node conditions"
oc get node $W2 -o jsonpath='{range .status.conditions[*]}{.type}={.status} ({.reason}) since {.lastTransitionTime}{"\n"}{end}'
oc get node $W2 -o jsonpath='capacity gaudi={.status.capacity.habana\.ai/gaudi} allocatable gaudi={.status.allocatable.habana\.ai/gaudi}{"\n"}'
hr "Boot time, kernel log for Gaudi / memory / hangs"
oc debug node/$W2 -q -- chroot /host sh -c '
  echo "uptime: $(uptime)"; echo "booted: $(uptime -s)"
  echo "--- habanalabs kernel messages (last 25)"; dmesg -T | grep -iE "habanalabs|accel" | tail -25
  echo "--- OOM / hung task / MCE / NMI"; dmesg -T | grep -iE "out of memory|oom-kill|hung_task|blocked for more|mce|nmi|soft lockup|hard lockup" | tail -10
  echo "--- previous boot tail (if journald kept it)"; journalctl -b -1 -k --no-pager 2>/dev/null | tail -15
  echo "--- devices"; ls -l /dev/accel/ 2>/dev/null' 2>&1 | cut -c1-260
hr "Gaudi pods (driver, device plugin)"
oc get pods -n $HNS -o wide
hr "Device plugin health log"
oc logs -n $HNS $(oc get pods -n $HNS -o name | grep device-plugin | head -1) --tail=25 2>&1 | grep -vE '/sys/bus/pci/devices' | cut -c1-260
