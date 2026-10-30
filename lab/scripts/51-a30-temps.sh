#!/usr/bin/env bash
# Read-only: A30 temperature, power and limit on worker1, 3 readings 5 s apart.
#   bash lab/scripts/51-a30-temps.sh 2>&1 | tee 51-a30-temps.txt
W1=${W1:-worker1.ai154.dl154.dfw.ocp.run}
DP=$(oc get pods -n nvidia-gpu-operator --field-selector spec.nodeName=$W1 -o name 2>/dev/null | grep driver-daemonset | head -1)
[ -z "$DP" ] && { echo "NVIDIA driver pod not found on $W1:"; oc get pods -n nvidia-gpu-operator -o wide | grep -E "NAME|$W1"; exit 1; }
echo "time, index, name, bus, temp C, power W, power limit W, util %"
for i in 1 2 3; do
  oc exec -n nvidia-gpu-operator $DP -- nvidia-smi --query-gpu=timestamp,index,name,pci.bus_id,temperature.gpu,power.draw,power.limit,utilization.gpu --format=csv,noheader 2>&1
  [ $i -lt 3 ] && sleep 5
done
