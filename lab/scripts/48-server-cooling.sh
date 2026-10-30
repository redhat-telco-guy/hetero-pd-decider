#!/usr/bin/env bash
# Read-only: server-side cooling facts for the Gaudi server vs the A30 server: model and BIOS, fan speeds,
# inlet/ambient and other temperature sensors, power readings and chassis status from the BMC (IPMI).
#   bash lab/scripts/48-server-cooling.sh 2>&1 | tee 48-server-cooling.txt
set -uo pipefail
oc whoami >/dev/null 2>&1 || { echo "Not logged in. Run oc login first."; exit 1; }
for n in $(oc get nodes -l node-role.kubernetes.io/worker -o name | sed 's#node/##'); do
  printf '\n######## %s\n' "$n"
  # The OpenShift debug pod runs the support-tools image, which ships ipmitool and dmidecode.
  oc debug node/$n -q -- sh -c '
    echo "--- server model and firmware"
    dmidecode -s system-manufacturer 2>/dev/null; dmidecode -s system-product-name 2>/dev/null
    echo "BIOS $(dmidecode -s bios-version 2>/dev/null) ($(dmidecode -s bios-release-date 2>/dev/null))"
    chroot /host sh -c "modprobe ipmi_devintf 2>/dev/null; modprobe ipmi_si 2>/dev/null; ls /dev/ipmi* 2>/dev/null" | sed "s/^/IPMI device: /"
    if ! command -v ipmitool >/dev/null; then echo "ipmitool not in this debug image"; exit 0; fi
    if ! ipmitool mc info >/dev/null 2>&1; then echo "BMC not reachable from the OS (IPMI driver/device missing): ask the lab owner for BMC fan/thermal readings"; exit 0; fi
    echo "--- BMC"; ipmitool mc info 2>/dev/null | grep -E "Manufacturer Name|Product Name|Firmware Revision"
    echo "--- fans"; ipmitool sdr type Fan 2>/dev/null
    echo "--- temperatures (inlet/ambient first)"; ipmitool sdr type Temperature 2>/dev/null | sort -k1 | grep -iE "inlet|ambient|intake|front" ; ipmitool sdr type Temperature 2>/dev/null | grep -viE "inlet|ambient|intake|front" | head -40
    echo "--- power"; ipmitool dcmi power reading 2>/dev/null | grep -E "Instantaneous|Average|Maximum"; ipmitool sdr type "Power Supply" 2>/dev/null | head -8
    echo "--- chassis"; ipmitool chassis status 2>/dev/null | grep -iE "fault|cooling|fan|overload|power"
  ' 2>&1 | cut -c1-200
done
