#!/usr/bin/env bash
# Read-only: fan speeds, inlet temperature, power and chassis faults from each worker's BMC.
# The default debug image has no ipmitool, so this starts a debug pod from the Fedora image and installs it there.
#   bash lab/scripts/49-bmc-readings.sh 2>&1 | tee 49-bmc-readings.txt
set -uo pipefail
oc whoami >/dev/null 2>&1 || { echo "Not logged in. Run oc login first."; exit 1; }
IMG=${IMG:-registry.fedoraproject.org/fedora:41}
for n in $(oc get nodes -l node-role.kubernetes.io/worker -o name | sed 's#node/##'); do
  printf '\n######## %s\n' "$n"
  oc debug node/$n -q --image=$IMG -- bash -c '
    dnf -y -q install ipmitool >/dev/null 2>&1 || { echo "could not install ipmitool (no internet from the node?)"; exit 0; }
    ls /dev/ipmi* >/dev/null 2>&1 || { echo "no /dev/ipmi* in the debug pod"; exit 0; }
    ipmitool mc info >/dev/null 2>&1 || { echo "BMC not answering over in-band IPMI"; exit 0; }
    echo "--- BMC";   ipmitool mc info | grep -E "Manufacturer Name|Product Name|Firmware Revision"
    echo "--- fans";  ipmitool sdr type Fan
    echo "--- inlet / ambient"; ipmitool sdr type Temperature | grep -iE "inlet|ambient|intake|front|sys"
    echo "--- other temperatures"; ipmitool sdr type Temperature | grep -viE "inlet|ambient|intake|front" | head -40
    echo "--- power"; ipmitool dcmi power reading 2>/dev/null | grep -E "Instantaneous|Average|Maximum"; ipmitool sdr type "Power Supply" | head -10
    echo "--- chassis"; ipmitool chassis status | grep -iE "fault|cooling|fan|overload|power"
    echo "--- recent BMC event log"; ipmitool sel elist 2>/dev/null | tail -25
  ' 2>&1 | cut -c1-200
done
