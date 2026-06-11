#!/bin/bash
# Create a worker from the shared base.qcow2 (built by `make base`): a thin
# overlay root plus fresh data disks, with identity written into the overlay.
# Fast - no per-worker bake. Then launch it with run.sh.
# Run on the worker host (root; needs qemu-nbd, mkfs.btrfs, mkfs.ext4).
#
# Usage: ./new-worker.sh <worker-name> [size]
set -e

name=$1
size=${2:-50G}
[ -n "$name" ] || { echo "usage: $0 <worker-name> [size]"; exit 1; }
cd "$(dirname "$0")"
[ -f base.qcow2 ] || { echo "no base.qcow2 - run 'make base' first"; exit 1; }
[ -e "${name}.qcow2" ] && { echo "${name}.qcow2 already exists"; exit 1; }

qemu-img create -f qcow2 -b base.qcow2 -F qcow2 "${name}.qcow2" "$size" >/dev/null
qemu-img create -f qcow2 "${name}-docker.qcow2" "$size" >/dev/null
qemu-img create -f qcow2 "${name}-obuilder.qcow2" "$size" >/dev/null

modprobe nbd max_part=8
ND=/dev/nbd0
mp=$(mktemp -d)
nbd_off() { umount "$mp" 2>/dev/null || true; qemu-nbd -d "$ND" >/dev/null 2>&1 || true; }
trap 'nbd_off; rmdir "$mp" 2>/dev/null || true' EXIT

# Attach $1 to $ND and wait until the kernel sees a non-zero size (avoids the
# "device size reported to be zero" race right after qemu-nbd -c).
nbd_connect() {
    qemu-nbd -d "$ND" >/dev/null 2>&1 || true
    qemu-nbd -c "$ND" "$1"
    udevadm settle >/dev/null 2>&1 || true
    local i
    for i in $(seq 1 120); do
        [ "$(blockdev --getsize64 "$ND" 2>/dev/null || echo 0)" -gt 0 ] && return 0
        sleep 0.5
    done
    echo "ERROR: $ND not ready for $1"; return 1
}

# obuilder store: btrfs + worker state-dir
nbd_connect "${name}-obuilder.qcow2"
mkfs.btrfs -f -L obuilder "$ND" >/dev/null
mount "$ND" "$mp"; mkdir -p "$mp/ocluster"; umount "$mp"

# docker data-root: ext4
nbd_connect "${name}-docker.qcow2"
mkfs.ext4 -F -L docker "$ND" >/dev/null

# overlay root: set hostname (worker --name follows it via systemd %H)
nbd_connect "${name}.qcow2"
partprobe "$ND" 2>/dev/null || true; sleep 1
root=""
for part in "$ND"p*; do
    [ -b "$part" ] || continue
    mount "$part" "$mp" 2>/dev/null || continue
    if [ -f "$mp/etc/os-release" ]; then root="$part"; break; fi
    umount "$mp"
done
[ -n "$root" ] || { echo "ERROR: no root partition found in ${name}.qcow2"; exit 1; }
echo "$name" > "$mp/etc/hostname"
printf '127.0.1.1\t%s\n' "$name" >> "$mp/etc/hosts"
umount "$mp"
qemu-nbd -d "$ND"

echo "${name}: created (overlay on base.qcow2, hostname=${name})"
