#!/usr/bin/env bash
# Read-only health check of every NVIDIA and Intel Gaudi card on the cluster: are they all seen,
# any boot errors, and how hot are they. Safe during a cluster upgrade and before any operator is installed.
#   bash lab/scripts/36-card-health.sh 2>&1 | tee 36-card-health.txt
set -uo pipefail
hr() { printf '\n==== %s ====\n' "$1"; }
oc whoami >/dev/null 2>&1 || { echo "Not logged in to the new cluster. Run its oc login command first."; exit 1; }
hr "Cluster"
echo "API: $(oc whoami --show-server)"
oc get clusterversion version -o jsonpath='version {.status.desired.version}  progressing={.status.conditions[?(@.type=="Progressing")].status}  {.status.conditions[?(@.type=="Progressing")].message}{"\n"}'
oc get nodes -o wide
hr "Hardware on each worker (PCI scan, drivers, kernel messages, temperatures)"
for n in $(oc get nodes -l node-role.kubernetes.io/worker -o name | sed 's#node/##'); do
  echo; echo "######## $n"
  if ! oc get node $n -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' | grep -q True; then
    echo "  node not Ready (may be rebooting for the upgrade); run this again in a few minutes"; continue; fi
  oc debug node/$n -q -- chroot /host sh -c '
    nv=$(lspci -d 10de: 2>/dev/null | grep -ciE "3d controller|vga|processing"); hb=$(lspci -d 1da3: 2>/dev/null | wc -l)
    echo "  NVIDIA cards on PCI: $nv    Intel Gaudi cards on PCI: $hb"
    [ "$nv$hb" = "00" ] && exit 0
    lspci -nn -d 10de: 2>/dev/null | grep -iE "3d controller|vga|processing" | sed "s/^/    /"
    lspci -nn -d 1da3: 2>/dev/null | sed "s/^/    /"
    for a in $(lspci -d 10de: 2>/dev/null | grep -iE "3d controller|vga|processing" | cut -d" " -f1) $(lspci -d 1da3: 2>/dev/null | cut -d" " -f1); do
      l=$(lspci -vv -s $a 2>/dev/null | grep -m1 "LnkSta:" | sed "s/^[[:space:]]*//" | cut -c1-60); echo "    $a link: ${l:-unknown}"; done
    echo "  drivers loaded: nvidia=$(lsmod | grep -c "^nvidia ") habanalabs=$(lsmod | grep -c "^habanalabs ")"
    echo "  booted: $(uptime -s)"
    echo "  --- card errors in the kernel log since boot"
    dmesg -T 2>/dev/null | grep -iE "habanalabs.*(error|fail|NOT usable|fatal|temperature|thermal)|NVRM.*(Xid|error|fail)|GPU has fallen off" | tail -15 | sed "s/^/    /"
    dmesg -T 2>/dev/null | grep -iE "habanalabs.*(error|fail|NOT usable|fatal)|NVRM.*(Xid|fail)" | grep -q . || echo "    none"
    echo "  --- temperatures the driver reports (deg C), if a driver is loaded"
    found=0; for h in /sys/class/hwmon/hwmon*; do nm=$(cat $h/name 2>/dev/null)
      case "$nm" in habanalabs*|nvidia*|nouveau*) found=1; dev=$(basename $(readlink -f $h/device) 2>/dev/null)
        for t in $h/temp*_input; do [ -f "$t" ] || continue; lb=$(cat ${t%_input}_label 2>/dev/null || basename $t); echo "    $dev $nm $lb: $(( $(cat $t) / 1000 ))"; done;;
      esac; done
    [ $found = 0 ] && echo "    no driver yet: temperatures appear once the GPU operators are installed"
    if command -v ipmitool >/dev/null 2>&1; then echo "  --- server sensors (BMC)"; ipmitool sdr type temperature 2>/dev/null | head -25 | sed "s/^/    /"; fi
  ' 2>&1 | cut -c1-220
done
hr "If the GPU operators are already installed"
EP=$(oc get pods -n habana-ai-operator -o name 2>/dev/null | grep metric-exporter)
for p in $EP; do node=$(oc get -n habana-ai-operator $p -o jsonpath='{.spec.nodeName}'); PORT=$(oc get -n habana-ai-operator $p -o jsonpath='{.spec.containers[0].ports[0].containerPort}')
  echo "-- Gaudi metrics from $node"
  oc get --raw "/api/v1/namespaces/habana-ai-operator/pods/$(basename $p):$PORT/proxy/metrics" 2>/dev/null \
   | grep -E '^habanalabs_(temperature_onchip|temperature_onboard|temperature_threshold_shutdown|power_mW|utilization|pending_rows_with_double_bit_ecc_errors|pcie_replay_count)\{' \
   | sed -E 's/\{.*Serial="([^"]*)".*\}/ serial=\1/' ; done
[ -z "$EP" ] && echo "Gaudi operator not installed yet (no metric exporter)"
for p in $(oc get pods -n nvidia-gpu-operator -o name 2>/dev/null | grep driver-daemonset); do
  echo "-- nvidia-smi on $(oc get -n nvidia-gpu-operator $p -o jsonpath='{.spec.nodeName}')"
  oc exec -n nvidia-gpu-operator $p -- nvidia-smi --query-gpu=index,name,pci.bus_id,temperature.gpu,power.draw,utilization.gpu,ecc.errors.uncorrected.volatile.total --format=csv 2>&1; done
oc get pods -n nvidia-gpu-operator -o name 2>/dev/null | grep -q driver-daemonset || echo "NVIDIA operator not installed yet (no driver pods)"
