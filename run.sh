#!/bin/bash
# Launch baked riscv64 OCluster worker VMs under QEMU emulation.
#
# Usage: ./run.sh
#
# Auto-discovers every built worker in this directory (each is a root disk
# <name>.qcow2 plus <name>-docker.qcow2 and <name>-obuilder.qcow2) and starts
# it, assigning an SSH-forward port (60022+) and VNC display (:0+) by index.
# Networking is user-mode NAT: outbound to the scheduler works without any
# forwarding; the SSH port is only for debugging. There is no KVM for riscv64
# on these hosts, so they run under TCG emulation (QEMU 11, see `make qemu`).
#
# NUMA-aware pinning (PIN_CORES): when set, each worker is placed on a single
# NUMA node -- its RAM bound there with `numactl --membind` and its SMP vCPU
# threads pinned 1:1 onto that node's cores. This is the precise form of the
# `numactl --cpunodebind --membind` whole-VM bind (cf. windows_worker/run.sh);
# the 1:1 vCPU pin is needed on hosts booted with `isolcpus`, where a broad
# affinity mask gets no load-balancing and the vCPU threads bunch. PIN_CORES is
# the set of cores you may use; workers are spread across nodes, node-local:
#
#   PIN_CORES=4-63,68-127 ./run.sh
#
# Leave PIN_CORES unset on normal hosts (the scheduler spreads vCPUs fine, and
# single-socket boxes have no NUMA locality to win).

set -e

MEM=${MEM:-16G}
SMP=${SMP:-8}
QEMU=${QEMU:-qemu-system-riscv64}   # resolves to the QEMU 11 build in /usr/local via PATH
PIN_CORES=${PIN_CORES:-}            # e.g. "4-63,68-127"; empty = no pinning / no NUMA bind

# Expand a "a-b,c,d-e" core list into space-separated integers.
expand_list() {
    local part out=""
    local IFS=','
    for part in $1; do
        if [[ "$part" == *-* ]]; then
            local c; for c in $(seq "${part%-*}" "${part#*-}"); do out+="$c "; done
        else
            out+="$part "
        fi
    done
    echo "$out"
}

# Per-node pool of usable cores (node cpulist ∩ PIN_CORES), consumed as workers start.
declare -A NODE_AVAIL=()
declare -a NODE_IDS=()
USE_PIN=0
if [ -n "$PIN_CORES" ]; then
    USE_PIN=1
    declare -A _allowed=()
    for c in $(expand_list "$PIN_CORES"); do _allowed[$c]=1; done
    for nd in /sys/devices/system/node/node[0-9]*; do
        [ -e "$nd/cpulist" ] || continue
        node=${nd##*/node}
        list=""
        for c in $(expand_list "$(cat "$nd/cpulist")"); do [ -n "${_allowed[$c]:-}" ] && list+="$c "; done
        if [ -n "$list" ]; then NODE_AVAIL[$node]="$list"; NODE_IDS+=("$node"); fi
    done
    command -v numactl >/dev/null || echo "WARNING: numactl not found (make deps) - RAM will not be node-bound"
fi

# Pick an SMP-sized block of cores from the node with the most spare (keeps
# workers balanced across sockets). Sets ALLOC_NODE and ALLOC_CORES.
ALLOC_NODE=""; ALLOC_CORES=""
alloc_block() {
    ALLOC_NODE=""; ALLOC_CORES=""
    local n cnt best="" bestn=0
    for n in "${NODE_IDS[@]}"; do
        cnt=$(echo ${NODE_AVAIL[$n]} | wc -w)
        if [ "$cnt" -ge "$SMP" ] && [ "$cnt" -gt "$bestn" ]; then bestn=$cnt; best=$n; fi
    done
    [ -z "$best" ] && return 1
    local arr=(${NODE_AVAIL[$best]})
    ALLOC_CORES="${arr[*]:0:$SMP}"
    NODE_AVAIL[$best]="${arr[*]:$SMP}"
    ALLOC_NODE="$best"
}

# Pin a worker's vCPU threads 1:1 onto the given cores (vCPU N -> Nth core).
pin_worker_vcpus() {
    local pid=$1; shift; local cores=("$@")
    local tries comm idx tid pinned=0
    for tries in $(seq 1 30); do
        pinned=0
        for t in /proc/"$pid"/task/*; do
            comm=$(cat "$t/comm" 2>/dev/null) || continue
            case "$comm" in
                "CPU "*"/TCG"|"CPU "*"/KVM")
                    idx=${comm#CPU }; idx=${idx%%/*}
                    tid=${t##*/}
                    [ -n "${cores[$idx]:-}" ] && taskset -pc "${cores[$idx]}" "$tid" >/dev/null 2>&1 && pinned=$((pinned + 1))
                    ;;
            esac
        done
        [ "$pinned" -ge "$SMP" ] && break
        sleep 1
    done
    echo "    node ${ALLOC_NODE}: pinned ${pinned}/${SMP} vCPUs to cores ${cores[*]}"
}

start_vm() {
    local name=$1 ssh_port=$2 vnc_display=$3

    if pgrep -f "system-riscv64.*${name}\.qcow2" >/dev/null 2>&1; then
        echo "${name}: already running"
        return
    fi

    local numa=""
    declare -a cores=()
    if [ "$USE_PIN" = 1 ]; then
        if alloc_block; then
            cores=($ALLOC_CORES)
            command -v numactl >/dev/null && numa="numactl --membind=${ALLOC_NODE}"
        else
            echo "    WARNING: no NUMA node has $SMP spare cores left; starting ${name} unpinned"
        fi
    fi

    echo "${name}: starting (ssh=${ssh_port} vnc=:${vnc_display})"
    nohup ${numa} ${QEMU} -cpu rva23s64 -m ${MEM} -smp ${SMP} -machine virt,acpi=off \
        -kernel /usr/lib/u-boot/qemu-riscv64_smode/uboot.elf \
        -display none -vnc :${vnc_display} -serial file:${name}-console.log \
        -drive file=${name}.qcow2,if=virtio \
        -drive file=${name}-docker.qcow2,if=virtio \
        -drive file=${name}-obuilder.qcow2,if=virtio \
        -device virtio-rng-pci \
        -netdev user,id=net0,hostfwd=tcp::${ssh_port}-:22 \
        -device virtio-net-device,netdev=net0 \
        </dev/null >${name}.log 2>&1 &
    local pid=$!
    echo "${name}: pid $pid"

    [ "${#cores[@]}" -gt 0 ] && pin_worker_vcpus "$pid" "${cores[@]}"
}

idx=0
shopt -s nullglob
for root in *.qcow2; do
    case "$root" in *-docker.qcow2|*-obuilder.qcow2) continue ;; esac
    name=${root%.qcow2}
    [ -f "${name}-docker.qcow2" ] && [ -f "${name}-obuilder.qcow2" ] || continue
    start_vm "$name" $((60022 + idx)) "$idx"
    idx=$((idx + 1))
done
[ "$idx" -eq 0 ] && echo "no built worker images found in $(pwd)"
