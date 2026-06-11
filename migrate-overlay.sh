#!/bin/bash
# Migrate a standalone full-root worker to a copy-on-write overlay on base.qcow2,
# reclaiming its ~17G full root. The docker and obuilder data disks are kept
# untouched (same LABEL=docker / LABEL=obuilder the base's fstab mounts), so the
# obuilder build cache survives the migration. Identity is preserved: the base
# unit takes --name from the hostname (%H), and we write the worker's name into
# the new overlay's /etc/hostname.
#
# Stops the VM, swaps the root, and leaves it stopped; re-launch with run.sh.
# Run on the worker host (root; needs qemu-nbd).
#
# Usage: ./migrate-overlay.sh <worker-name>
set -e

name=$1
[ -n "$name" ] || { echo "usage: $0 <worker-name>"; exit 1; }
cd "$(dirname "$0")"
[ -f base.qcow2 ] || { echo "no base.qcow2 - run 'make base' first"; exit 1; }
[ -f "${name}.qcow2" ] || { echo "no such worker: ${name}.qcow2"; exit 1; }
[ -f "${name}-docker.qcow2" ] && [ -f "${name}-obuilder.qcow2" ] \
    || { echo "ERROR: ${name} data disks missing - refusing to migrate"; exit 1; }

# Already an overlay on base? Nothing to do.
if qemu-img info "${name}.qcow2" 2>/dev/null | grep -q "backing file:.*base.qcow2"; then
    echo "${name}: already an overlay on base.qcow2 - skipping"; exit 0
fi

# Stop the VM. The ".qcow2," boundary stops navajo-1 matching navajo-10/11.
pid=$(pgrep -f "file=${name}.qcow2,if=virtio" || true)
if [ -n "$pid" ]; then
    echo "stopping ${name} (pid ${pid})"
    kill "$pid" 2>/dev/null || true
    for _ in $(seq 1 90); do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
    kill -9 "$pid" 2>/dev/null || true
    sleep 2
fi

# Swap the full root for an overlay. Keep the old root aside until the overlay
# is built and its identity is written, so a failure cannot lose the worker.
# The overlay inherits base.qcow2's virtual size (no size arg): it must NOT be
# smaller than the backing, or base's GPT/partitions overrun the device and no
# partition table is found. Old roots vary in size (some 40G, some 50G), so
# never size the overlay from the old root.
mv "${name}.qcow2" "${name}.qcow2.old"
qemu-img create -f qcow2 -b base.qcow2 -F qcow2 "${name}.qcow2" >/dev/null

modprobe nbd max_part=8
ND=/dev/nbd0
mp=$(mktemp -d)
trap 'umount "$mp" 2>/dev/null || true; qemu-nbd -d "$ND" >/dev/null 2>&1 || true; rmdir "$mp" 2>/dev/null || true' EXIT

# Attach $1 to $ND and wait until the kernel sees a non-zero size.
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

# Write identity into the new overlay root (worker --name follows it via %H).
nbd_connect "${name}.qcow2"
# Trigger ONE partition rescan, then wait for the nodes to appear. Do NOT
# re-run partprobe in the loop: each call tears down and recreates the
# partition nodes, and under heavy host load udev takes >1s to recreate them,
# so a re-probing loop keeps missing the window and never finds a partition.
partprobe "$ND" 2>/dev/null || true
root=""
for try in $(seq 1 60); do
    udevadm settle >/dev/null 2>&1 || true
    for part in "$ND"p*; do
        [ -b "$part" ] || continue
        mount "$part" "$mp" 2>/dev/null || continue
        if [ -f "$mp/etc/os-release" ]; then root="$part"; break 2; fi
        umount "$mp"
    done
    sleep 0.5
done
if [ -z "$root" ]; then
    echo "ERROR: no root partition in new overlay - restoring old root"
    qemu-nbd -d "$ND" >/dev/null 2>&1 || true
    rm -f "${name}.qcow2"; mv "${name}.qcow2.old" "${name}.qcow2"
    exit 1
fi
echo "$name" > "$mp/etc/hostname"
printf '127.0.1.1\t%s\n' "$name" >> "$mp/etc/hosts"
umount "$mp"
qemu-nbd -d "$ND"

rm -f "${name}.qcow2.old"
echo "${name}: migrated to overlay on base.qcow2 (data disks + cache kept)"
