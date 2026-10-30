#!/usr/bin/env bash
# Try to bring Gaudi 0000:c9:00.0 back without a power cycle: inspect PCIe, rescan the bus,
# and if the card reappears, restart the Gaudi driver pod so it initializes it.
W2=worker2.ai154.dl154.dfw.ocp.run; HNS=habana-ai-operator
hr() { printf '\n==== %s ====\n' "$1"; }
oc whoami >/dev/null 2>&1 || { echo "Cannot reach cluster; reconnect and oc login, then re-run."; exit 1; }

hr "Before: PCIe state and error log for the c9 slot"
oc debug node/$W2 -q -- chroot /host sh -c '
  echo "--- Gaudi devices on the bus"; lspci -nn | grep -i 1da3
  echo "--- PCI tree around bus c8-ca"; lspci -tv 2>/dev/null | grep -iE "c[89a]|1da3" | head -10
  echo "--- root ports for bus c9 (link status)"; for d in $(lspci -D | awk "/PCI bridge/ {print \$1}"); do
      sec=$(cat /sys/bus/pci/devices/$d/secondary_bus_number 2>/dev/null); [ "$sec" = "201" ] && { echo "root port $d -> bus c9"; lspci -vvs $d | grep -iE "LnkSta:|LnkCap:|SltSta|Presence|DLActive"; }; done
  echo "--- AER / pcieport / hotplug messages, previous boot"; journalctl -b -1 -k --no-pager 2>/dev/null | grep -iE "aer|pcieport|c9:00|link down|surprise|hotplug|thermal" | tail -15
  echo "--- AER / pcieport messages, this boot";     dmesg -T | grep -iE "aer|pcieport|c9:00|link down|hotplug" | tail -10' 2>&1 | cut -c1-240

hr "Rescan the PCI bus"
oc debug node/$W2 -q -- chroot /host sh -c 'echo 1 > /sys/bus/pci/rescan; sleep 5; lspci -nn | grep -i 1da3; dmesg -T | tail -8' 2>&1 | cut -c1-240

if oc debug node/$W2 -q -- chroot /host sh -c 'lspci -nn | grep -qi "^c9:00.0.*1da3"' 2>/dev/null; then
  hr "c9:00.0 is back on the bus: restarting the Gaudi driver pod to initialize it"
  oc delete pod -n $HNS $(oc get pods -n $HNS -o name | grep driver | sed 's#pod/##') --wait=false
  for i in $(seq 1 30); do
    hb=$(oc get node $W2 -o jsonpath='{.status.allocatable.habana\.ai/gaudi}')
    echo "[$i $(date +%H:%M)] allocatable habana.ai/gaudi=${hb:-0}"; [ "${hb:-0}" -ge 1 ] && break; sleep 20
  done
  oc debug node/$W2 -q -- chroot /host sh -c 'dmesg -T | grep -i "c9:00.0" | tail -10' 2>&1 | cut -c1-240
else
  echo "c9:00.0 did not reappear after rescan. It needs a full power-off of worker2 (BMC power cycle or AC removal)."
fi
