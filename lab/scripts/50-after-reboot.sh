#!/usr/bin/env bash
# Read-only check after worker2 reboot: node state, Gaudi workloads still stopped, card temperatures and power
# and the same for the A30 server (worker1) side by side
# (from the in-cluster watchdog, the only reader of the Gaudi exporter), and worker2's BMC fans/temps/power.
#   bash lab/scripts/50-after-reboot.sh 2>&1 | tee 50-after-reboot.txt
set -uo pipefail
NS=hetero-pd-lab; W2=${W2:-worker2.ai154.dl154.dfw.ocp.run}; W1=${W1:-worker1.ai154.dl154.dfw.ocp.run}; REPO=$(cd "$(dirname "$0")/../.." && pwd)
IMG=${IMG:-registry.fedoraproject.org/fedora:41}
hr() { printf '\n==== %s ====\n' "$1"; }
oc whoami >/dev/null 2>&1 || { echo "Not logged in. Run oc login first."; exit 1; }

hr "1. worker2 node"
oc get node $W2 -o wide | cut -c1-120
oc debug node/$W2 -q -- chroot /host sh -c 'echo "up since: $(uptime -s)"; ls /dev/accel* 2>/dev/null | tr "\n" " "; echo' 2>&1 | tail -3

hr "2. Gaudi workloads (should be 0 replicas)"
oc get deploy -n $NS -o custom-columns=NAME:.metadata.name,WANT:.spec.replicas,READY:.status.readyReplicas | grep -iE "NAME|gaudi|habana"

hr "3. Gaudi card temperature and power (watchdog readings, every 5 s)"
if ! oc get deploy gaudi-watchdog -n $NS >/dev/null 2>&1 || [ "$(oc get deploy gaudi-watchdog -n $NS -o jsonpath='{.status.readyReplicas}')" != "1" ]; then
  echo "watchdog not running: starting it (it only reads, and stops Gaudi work at 80 C)"
  bash $REPO/lab/mixed/45-watchdog-incluster.sh >/dev/null 2>&1
  oc rollout status deploy/gaudi-watchdog -n $NS --timeout=180s
fi
echo "waiting 40 s for fresh readings..."; sleep 40
echo "time(UTC),           serial,        chip C, board C, power W, util %"
oc logs deploy/gaudi-watchdog -n $NS --since=60s 2>/dev/null | grep '^csv,' | grep -v ',time,' | tail -8 | cut -d, -f2-
oc logs deploy/gaudi-watchdog -n $NS --since=60s 2>/dev/null | grep -viE '^csv' | tail -5

hr "4. worker2 BMC: fans, temperatures, power"
oc debug node/$W2 -q --image=$IMG -- bash -c '
  dnf -y -q install ipmitool >/dev/null 2>&1 || { echo "could not install ipmitool"; exit 0; }
  ipmitool sdr type Fan | grep -E "Zone|_[01] "
  ipmitool sdr type Temperature | grep -E "Inlet|OCP_ASIC0|PCIE|CPU[01] |PSU"
  ipmitool dcmi power reading 2>/dev/null | grep Instantaneous
  ipmitool chassis status | grep -E "Cooling|Overload"
  echo "--- BMC events since reboot"; ipmitool sel elist 2>/dev/null | tail -12
' 2>&1 | cut -c1-160

hr "5. A30 card temperature and power (nvidia-smi, 3 readings 5 s apart)"
DP=$(oc get pods -n nvidia-gpu-operator --field-selector spec.nodeName=$W1 -o name 2>/dev/null | grep driver-daemonset | head -1)
if [ -n "$DP" ]; then
  echo "time, index, name, bus, temp C, power W, power limit W, util %, fan %"
  for i in 1 2 3; do
    oc exec -n nvidia-gpu-operator $DP -- nvidia-smi --query-gpu=timestamp,index,name,pci.bus_id,temperature.gpu,power.draw,power.limit,utilization.gpu,fan.speed --format=csv,noheader 2>&1
    [ $i -lt 3 ] && sleep 5
  done
else echo "NVIDIA driver pod not found on $W1"; fi

hr "6. worker1 (A30 server) BMC: fans, temperatures, power"
oc debug node/$W1 -q --image=$IMG -- bash -c '
  dnf -y -q install ipmitool >/dev/null 2>&1 || { echo "could not install ipmitool"; exit 0; }
  ipmitool sdr type Fan | grep -E "Fan[0-9][AB] |Redundancy"
  ipmitool sdr type Temperature | grep -E "Inlet|Exhaust|^Temp  "
  ipmitool dcmi power reading 2>/dev/null | grep Instantaneous
  ipmitool chassis status | grep -E "Cooling|Overload"
' 2>&1 | cut -c1-160
