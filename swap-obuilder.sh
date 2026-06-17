#!/bin/bash
# Replace a worker's obuilder btrfs disk with a fresh one (resets the obuilder
# cache and state-dir, so the worker pays the cold-build tax again, but bounds
# host disk use). Run on the worker host. Re-launch with run.sh afterwards.
#
# Usage: ./swap-obuilder.sh <worker-name> [size]
#   ./swap-obuilder.sh riscv-qemu-navajo-1 50G
set -e

name=$1
size=${2:-50G}
[ -n "$name" ] || { echo "usage: $0 <worker-name> [size]"; exit 1; }
[ -f "${name}.qcow2" ] || { echo "no such worker in $(pwd): ${name}.qcow2"; exit 1; }
. "$(dirname "$0")/lib-stopvm.sh"

# 1. Stop the VM cleanly (clean guest poweroff avoids corrupting docker/BuildKit).
stop_vm "$name"

# 2. Fresh obuilder disk.
rm -f "${name}-obuilder.qcow2"
qemu-img create -f qcow2 "${name}-obuilder.qcow2" "$size" >/dev/null

# 3. Format btrfs with the LABEL fstab expects, and pre-create the state-dir.
modprobe nbd max_part=8
qemu-nbd -d /dev/nbd0 2>/dev/null || true
qemu-nbd -c /dev/nbd0 "${name}-obuilder.qcow2"
sleep 1
mkfs.btrfs -f -L obuilder /dev/nbd0 >/dev/null
mp=$(mktemp -d)
mount /dev/nbd0 "$mp"
mkdir -p "$mp/ocluster"
umount "$mp"
rmdir "$mp"
qemu-nbd -d /dev/nbd0

echo "${name}: obuilder disk reset to fresh ${size} btrfs (LABEL=obuilder)"
