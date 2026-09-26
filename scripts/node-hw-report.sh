#!/usr/bin/env bash
# Gather hardware inventory info from a Flatcar cluster node over SSH, in the
# same shape as the tables in docs/node-inventory.md (CPU, RAM/DIMMs, NIC
# MACs/link speed, storage, BIOS/chassis identifiers).
#
# Usage: scripts/node-hw-report.sh <host-or-ip> [ssh-user]
#   scripts/node-hw-report.sh 10.20.20.16
#   scripts/node-hw-report.sh wk-talos core

set -euo pipefail

HOST="${1:?usage: node-hw-report.sh <host-or-ip> [ssh-user]}"
USER="${2:-core}"

ssh -o StrictHostKeyChecking=accept-new "${USER}@${HOST}" 'bash -s' <<'REMOTE'
set -uo pipefail

section() { printf '\n=== %s ===\n' "$1"; }

section "hostname / kernel"
hostnamectl 2>/dev/null || uname -a

section "cpu"
lscpu 2>/dev/null | grep -E 'Model name|Socket|Core|Thread' || grep -m1 'model name' /proc/cpuinfo

section "memory (free)"
free -h

section "network interfaces (native)"
ip -o link show | awk -F': ' '{print $2}' | while read -r ifc; do
  ifc="${ifc%%@*}"
  [ "$ifc" = "lo" ] && continue
  mac=$(cat "/sys/class/net/${ifc}/address" 2>/dev/null || echo "?")
  printf '%-12s %s\n' "$ifc" "$mac"
done

section "block devices (native)"
lsblk -d -o NAME,MODEL,SIZE,SERIAL,ROTA 2>/dev/null

echo
echo "Installing toolbox utilities (dmidecode, ethtool, smartmontools, pciutils)..."
sudo toolbox bash -c '
  command -v dmidecode >/dev/null 2>&1 || dnf install -y -q dmidecode >/dev/null
  command -v ethtool    >/dev/null 2>&1 || dnf install -y -q ethtool >/dev/null
  command -v smartctl   >/dev/null 2>&1 || dnf install -y -q smartmontools >/dev/null
  command -v lspci      >/dev/null 2>&1 || dnf install -y -q pciutils >/dev/null

  echo
  echo "=== BIOS / system / baseboard (dmidecode -t 0,1,2) ==="
  dmidecode -t 0,1,2 2>/dev/null | grep -E "Vendor|Version|Release Date|Product Name|Manufacturer|Serial Number"

  echo
  echo "=== memory slots / DIMMs (dmidecode -t 16,17) ==="
  dmidecode -t 16 2>/dev/null | grep -E "Maximum Capacity"
  dmidecode -t 17 2>/dev/null | awk "
    /Memory Device/ {print \"---\"}
    /Locator:/ && !/Bank/ {print}
    /Size:/ {print}
    /Type:/ && !/Detail/ {print}
    /Speed:/ {print}
    /Manufacturer:/ {print}
  "

  echo
  echo "=== PCI devices (lspci -nn, for GPU / NIC / Thunderbolt controllers) ==="
  lspci -nn 2>/dev/null | grep -Ei "vga|3d controller|display|ethernet|network|thunderbolt|non-volatile"
'

echo
echo "=== NIC link speed (ethtool, via toolbox) ==="
for ifc in $(ip -o link show | awk -F': ' '{print $2}' | sed 's/@.*//'); do
  [ "$ifc" = "lo" ] && continue
  echo "-- $ifc --"
  sudo toolbox ethtool "$ifc" 2>/dev/null | grep -E "Speed|Link detected" || echo "  (no ethtool data)"
done

echo
echo "=== disk details (smartctl -i, /dev bind-mounted explicitly) ==="
# toolbox's default container doesn't bind-mount /dev, so raw block-device
# ioctls (smartctl) fail with "No such device" even though lspci/ethtool work
# fine via /sys and netlink. Run a one-off privileged container with /dev
# mounted instead of going through the toolbox wrapper.
DISKS="$(lsblk -d -no NAME | grep -v '^loop')"
if [ -n "$DISKS" ]; then
  sudo podman run --rm --privileged -v /dev:/dev -e DISKS="$DISKS" docker.io/library/fedora:latest bash -c '
    dnf install -y -q smartmontools >/dev/null 2>&1
    for dev in $DISKS; do
      echo "-- /dev/$dev --"
      smartctl -i "/dev/$dev" 2>/dev/null | grep -E "Model Number|Device Model|Serial Number|Rotation Rate|Firmware Version" || echo "  (no smartctl data)"
    done
  '
fi
REMOTE
