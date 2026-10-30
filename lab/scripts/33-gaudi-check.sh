#!/usr/bin/env bash
# Read-only: are the Gaudi cards on worker2 back? Safe to run while a test suite is running.
W2=worker2.ai154.dl154.dfw.ocp.run; HNS=habana-ai-operator
hr() { printf '\n==== %s ====\n' "$1"; }
hr "1. Node"
oc get node $W2 -o wide --no-headers 2>&1
oc get node $W2 -o jsonpath='{range .status.conditions[*]}{.type}={.status} since {.lastTransitionTime}{"\n"}{end}'
CAP=$(oc get node $W2 -o jsonpath='{.status.capacity.habana\.ai/gaudi}'); ALLOC=$(oc get node $W2 -o jsonpath='{.status.allocatable.habana\.ai/gaudi}')
echo "Gaudi cards Kubernetes sees: capacity=${CAP:-0} allocatable=${ALLOC:-0}"
hr "2. Hardware seen by the server (PCI, driver, kernel log)"
oc debug node/$W2 -q -- chroot /host sh -c '
  echo "booted: $(uptime -s)"
  echo "Habana PCI devices (vendor 1da3):"; lspci -nn -d 1da3: 2>/dev/null || echo "  lspci not available"
  echo "count: $(lspci -d 1da3: 2>/dev/null | wc -l)"
  echo "/dev/accel:"; ls /dev/accel/ 2>/dev/null || echo "  none"
  echo "driver loaded: $(lsmod | grep -c "^habanalabs")"
  echo "--- habanalabs kernel messages since boot (last 30)"; dmesg -T | grep -iE "habanalabs|accel" | tail -30' 2>&1 | cut -c1-240
hr "3. Gaudi operator pods on worker2"
oc get pods -n $HNS -o wide 2>&1 | awk 'NR==1 || /worker2/'
hr "4. hl-smi (card health, temperature, memory)"
P=$(oc get pods -n $HNS -o wide --no-headers 2>/dev/null | awk '/worker2/ && /driver/ {print $1; exit}')
if [ -n "$P" ]; then oc exec -n $HNS $P -- sh -c 'command -v hl-smi >/dev/null && hl-smi || (ls /opt/habanalabs 2>/dev/null; echo "hl-smi not in this pod")' 2>&1 | head -40
else echo "No driver pod on worker2"; fi
hr "5. Device plugin log (last 20)"
DP=$(oc get pods -n $HNS -o wide --no-headers 2>/dev/null | awk '/worker2/ && /device-plugin/ {print $1; exit}')
[ -n "$DP" ] && oc logs -n $HNS $DP --tail=20 2>&1 | grep -vE '/sys/bus/pci/devices' | cut -c1-240 || echo "No device plugin pod on worker2"
