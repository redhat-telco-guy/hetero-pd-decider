#!/usr/bin/env bash
# One read-only health and evidence run for both servers. Nothing is changed and no load is put on the cards.
#   bash lab/scripts/52-full-health.sh 2>&1 | tee 52-full-health.txt
# Covers: cluster/operator smoke test, fans (3 samples) and every BMC fan/temperature sensor WITH its alarm
# thresholds, which network card sits in the OCP slot (the 85 C chip) and its health, card temperatures with
# their limits, PCIe link and error counters, kernel errors since boot, and the worker1<->worker2 link.
set -uo pipefail
NS=hetero-pd-lab; IMG=${IMG:-registry.fedoraproject.org/fedora:41}
hr() { printf '\n\n==================== %s ====================\n' "$1"; }
oc whoami >/dev/null 2>&1 || { echo "Not logged in. Run oc login first."; exit 1; }
echo "run started $(date -u '+%Y-%m-%d %H:%M:%S UTC')"

hr "A. Cluster smoke test"
oc get nodes -o custom-columns=NODE:.metadata.name,READY:.status.conditions[-1].type,STATUS:.status.conditions[-1].status,A30s:.status.allocatable.nvidia\\.com/gpu,GAUDIS:.status.allocatable.habana\\.ai/gaudi
echo; echo "NVIDIA ClusterPolicy: $(oc get clusterpolicies.nvidia.com -o jsonpath='{.items[0].status.state}' 2>/dev/null)"
echo "Gaudi ClusterPolicy:  $(oc get clusterpolicies.habanalabs.habana.ai -o jsonpath='{range .items[*]}{.metadata.name}: {.status.state}{.status.phase}{"\n"}{end}' 2>/dev/null)"
echo; echo "Operator pods not Running/Completed:"
oc get pods -n nvidia-gpu-operator --no-headers 2>/dev/null | grep -vE "Running|Completed" || echo "  nvidia-gpu-operator: all fine"
oc get pods -n habana-ai-operator --no-headers 2>/dev/null | grep -vE "Running|Completed" || echo "  habana-ai-operator: all fine"
echo; echo "Lab pods ($NS):"; oc get pods -n $NS -o wide --no-headers 2>/dev/null | awk '{printf "  %-45s %-8s %-10s restarts=%s node=%s\n",$1,$2,$3,$4,$7}'
echo; echo "Who reads the Gaudi metrics (a second reader causes the 'Too Many Requests' gaps):"
oc get servicemonitors,podmonitors -A 2>/dev/null | grep -iE "habana|gaudi" || echo "  no Prometheus monitors on the Gaudi exporter"
echo "  watchdog: $(oc get deploy gaudi-watchdog -n $NS -o jsonpath='{.status.readyReplicas}/{.spec.replicas} ready' 2>/dev/null)"
echo "  'Too Many Requests' gaps in the last hour: $(oc logs deploy/gaudi-watchdog -n $NS --since=1h 2>/dev/null | grep -c 429)"

hr "B. Gaudi card temperatures (watchdog, last 30 s)"
echo "time(UTC), serial, chip C, board C, power W, util %"
oc logs deploy/gaudi-watchdog -n $NS --since=30s 2>/dev/null | grep '^csv,' | grep -v ',time,' | tail -6 | cut -d, -f2-

hr "C. A30 cards (worker1)"
W1=$(oc get pods -n nvidia-gpu-operator -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' | sort -u | head -1)
DP=$(oc get pods -n nvidia-gpu-operator -o name | grep driver-daemonset | head -1)
if [ -n "$DP" ]; then
  oc exec -n nvidia-gpu-operator $DP -- nvidia-smi --query-gpu=index,pci.bus_id,temperature.gpu,power.draw,power.limit,utilization.gpu,clocks_throttle_reasons.active,ecc.errors.uncorrected.volatile.total,pcie.link.gen.current,pcie.link.width.current --format=csv 2>&1
  echo; echo "A30 temperature limits:"
  oc exec -n nvidia-gpu-operator $DP -- nvidia-smi -q -d TEMPERATURE 2>&1 | grep -E "Shutdown|Slowdown|Max Operating|Target" | sort -u
else echo "NVIDIA driver pod not found"; fi

# ---------- per-node checks, run inside a privileged Fedora debug pod on each worker ----------
INNER=$(cat <<'EOS'
dnf -y -q install ipmitool ethtool pciutils dmidecode iputils >/dev/null 2>&1 || echo "WARN: could not install tools"
sec(){ printf '\n--- %s\n' "$1"; }
sec "server"
echo "$(dmidecode -s system-manufacturer) $(dmidecode -s system-product-name), BIOS $(dmidecode -s bios-version), BMC firmware $(ipmitool mc info 2>/dev/null | awk -F': ' '/Firmware Revision/{print $2}')"
echo "up since $(chroot /host uptime -s)"

sec "fans: 3 samples, 10 s apart"
for i in 1 2 3; do
  printf '%s  ' "$(date -u +%T)"
  ipmitool sdr type Fan 2>/dev/null | awk -F'|' '$5 ~ /RPM|percent/ {gsub(/ +$/,"",$1); gsub(/^ +| RPM| percent/,"",$5); printf "%s=%s ", $1, $5}'; echo
  [ $i -lt 3 ] && sleep 10
done
echo "(Fan_Zone values are percent; the rest are RPM)"

sec "power"
ipmitool dcmi power reading 2>/dev/null | grep -E "Instantaneous|Maximum|Average"

sec "every fan and temperature sensor that has a reading, with its alarm thresholds"
echo "sensor | value | unit | status | low-nonrecov | low-crit | low-warn | HIGH-WARN | HIGH-CRIT | high-nonrecov"
ipmitool sensor 2>/dev/null | awk -F'|' 'tolower($1) ~ /fan|temp|inlet|exhaust|ocp|pcie/ && $2 !~ /^ *na *$/ && $3 !~ /discrete/' | tr -s ' '

sec "sensors with no reading (the BMC cannot see these)"
ipmitool sdr 2>/dev/null | grep -iE "no reading" | awk -F'|' '{print $1}' | tr -s ' ' | tr '\n' ',' ; echo

sec "PCIe slots (what is plugged in where)"
dmidecode -t 9 2>/dev/null | awk '/Designation:/{sub(/.*Designation: /,"");d=$0} /Current Usage:/{u=$3} /Bus Address:/{if(u=="In") print "  " d " -> " $3}'

sec "network cards"
DEF=$(chroot /host ip route show default | awk '{print $5; exit}')
for i in /sys/class/net/*; do n=${i##*/}; [ -e $i/device ] || continue
  bdf=$(basename $(readlink -f $i/device)); drv=$(basename $(readlink -f $i/device/driver 2>/dev/null))
  echo "  $n  pci=$bdf  driver=$drv  state=$(cat $i/operstate)  speed=$(cat $i/speed 2>/dev/null)Mb/s  $( [ "$n" = "$DEF" ] && echo '<- cluster traffic (default route)')"
  echo "      $(lspci -s $bdf | cut -d' ' -f2-)"
done
for i in /sys/class/net/*; do n=${i##*/}; [ -e $i/device ] && [ "$(cat $i/operstate)" = up ] || continue
  echo "  [$n] module/transceiver:"; ethtool -m $n 2>/dev/null | grep -iE "identifier|Module temperature|warning|alarm" | grep -viE ": *off$|: *None" | head -6 | sed 's/^/      /'
  echo "  [$n] non-zero error/drop counters:"; ethtool -S $n 2>/dev/null | grep -iE "err|drop|discard|crc|timeout|over" | grep -vE ": 0$" | head -10 | sed 's/^/      /'
done

sec "chip temperatures the Linux drivers report (Gaudi, NICs, NVMe), with limits"
for h in /sys/class/hwmon/hwmon*; do nm=$(cat $h/name); [ "$nm" = coretemp ] && continue
  dev=$(basename $(readlink -f $h/device 2>/dev/null) 2>/dev/null)
  for t in $h/temp*_input; do [ -e "$t" ] || continue; b=${t%_input}
    v=$(( $(cat $t 2>/dev/null || echo 0) / 1000 )); lb=$(cat ${b}_label 2>/dev/null)
    mx=$(cat ${b}_max 2>/dev/null); cr=$(cat ${b}_crit 2>/dev/null)
    echo "  $nm $dev ${lb:-${b##*/}}: ${v} C   max=${mx:+$((mx/1000))} crit=${cr:+$((cr/1000))}"
  done; done | sort | uniq | head -40

sec "accelerators: PCIe link and error counters"
for d in $(lspci -D -d 1da3: | awk '{print $1}') $(lspci -D -d 10de: | awk '{print $1}'); do
  echo "  $d $(lspci -s $d | cut -d: -f3- | cut -c1-50)"
  lspci -s $d -vv 2>/dev/null | grep -E "LnkSta:" | sed 's/^\s*/      /' | cut -c1-80
  for f in correctable nonfatal fatal; do printf "      AER %-11s %s\n" $f "$(grep TOTAL /sys/bus/pci/devices/$d/aer_dev_$f 2>/dev/null | awk '{print $2}')"; done
done

sec "kernel errors/warnings since boot (cards, PCIe, thermal, machine checks)"
chroot /host journalctl -k -b --no-pager 2>/dev/null | grep -iE "habanalabs|nvrm|xid|thermal|throttl|aer|pcie bus error|mce|hardware error|temperature" | grep -iE "err|fail|warn|thermal|throttl|xid|critical|over|temperature" | tail -20 || true
echo "  (end)"

sec "BMC event log, last 10"
ipmitool sel elist 2>/dev/null | tail -10

sec "network link to the other worker (used for the KV handoff)"
ping -c 20 -i 0.2 -q $PEER 2>&1 | tail -2
EOS
)

W=($(oc get nodes -l node-role.kubernetes.io/worker -o jsonpath='{range .items[*]}{.metadata.name}{" "}{end}'))
IP=($(oc get nodes -l node-role.kubernetes.io/worker -o jsonpath='{range .items[*]}{.status.addresses[?(@.type=="InternalIP")].address}{" "}{end}'))
for k in "${!W[@]}"; do
  peer=${IP[$(( (k + 1) % ${#IP[@]} ))]}
  hr "D. ${W[$k]}"
  oc debug node/${W[$k]} -q --image=$IMG -- bash -c "PEER=$peer; $INNER" 2>&1 | cut -c1-220
done
echo; echo "run finished $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
