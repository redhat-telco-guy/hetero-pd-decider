#!/usr/bin/env bash
# Read-only hardware inventory of the worker nodes.
for n in worker1 worker2; do
  echo "==== $n ===="
  oc debug node/$n.ai154.dl154.dfw.ocp.run -q -- chroot /host sh -c \
    'lspci -nn | grep -Ei "nvidia|10de:|habana|1da3:" ; echo "--- cpu/mem"; nproc; free -g | head -2; echo "--- disks"; lsblk -d -o NAME,SIZE,TYPE,ROTA | grep -v loop'
done
echo "==== local python ===="
which python python3 2>&1
