#!/bin/bash
# Driver (runs on the admin machine): migrate all standalone-root navajo workers
# to overlays without interrupting a single job. Pauses them all up front, then
# as each drains to 0 running it is migrated (root -> overlay on base, data disks
# kept), relaunched, and unpaused once it reconnects. The rest of the pool keeps
# taking jobs throughout.
set -u
CAP=/home/mtelvers/admin.cap
POOL=linux-riscv64
HOST=navajo.caelum.ci.dev
DIR=/local/scratch/riscv_worker
PIN=4-63,68-127
ADMIN="ocluster-admin --connect $CAP"
WORKERS=$(seq 1 24)

show() { $ADMIN show $POOL 2>/dev/null; }

echo "=== pausing all standalone workers (1-24) ==="
for w in $WORKERS; do $ADMIN pause $POOL riscv-qemu-navajo-$w >/dev/null 2>&1 && echo "paused navajo-$w"; done

declare -A DONE=()
while :; do
    # done when every worker is migrated and none still marked paused
    s=$(show)
    remaining=""
    for w in $WORKERS; do [ -n "${DONE[$w]:-}" ] || remaining="$remaining $w"; done

    # unpause any migrated worker that has reconnected but is still paused
    for w in $WORKERS; do
        [ -n "${DONE[$w]:-}" ] || continue
        if grep -E "riscv-qemu-navajo-$w " <<<"$s" | grep -q "admin pause"; then
            $ADMIN unpause $POOL riscv-qemu-navajo-$w >/dev/null 2>&1 && echo "$(date +%H:%M:%S) unpaused navajo-$w"
        fi
    done

    if [ -z "$remaining" ]; then
        still_paused=$(grep -c "admin pause" <<<"$s" || true)
        [ "$still_paused" -eq 0 ] && { echo "=== ALL 24 MIGRATED AND UNPAUSED ==="; break; }
    fi

    # which remaining workers have drained to 0 running?
    ready=""
    for w in $remaining; do
        grep -E "riscv-qemu-navajo-$w " <<<"$s" | grep -q "(0 running)" && ready="$ready $w"
    done

    if [ -n "$ready" ]; then
        for w in $ready; do
            echo "$(date +%H:%M:%S) migrating navajo-$w ..."
            out=$(ssh -o ConnectTimeout=60 "$HOST" "cd $DIR && bash migrate-overlay.sh riscv-qemu-navajo-$w" 2>&1)
            echo "$out" | sed "s/^/    /"
            if grep -qE "migrated to overlay|already an overlay" <<<"$out"; then
                DONE[$w]=1
            else
                # A migrate failure leaves the worker stopped with its old root
                # restored. Do NOT march on through the rest of the fleet (that
                # was the churn bug); relaunch this one, unpause the whole pool
                # so nothing is left stuck paused, and abort for inspection.
                echo "$(date +%H:%M:%S) FATAL: navajo-$w migrate failed - relaunching it and aborting"
                ssh -o ConnectTimeout=60 "$HOST" "cd $DIR && setsid bash -c \"PIN_CORES=$PIN ./run.sh\" </dev/null >>run-mig.out 2>&1"
                $ADMIN unpause --all $POOL >/dev/null 2>&1
                exit 1
            fi
        done
        echo "$(date +%H:%M:%S) relaunching migrated VMs"
        ssh -o ConnectTimeout=60 "$HOST" "cd $DIR && setsid bash -c \"PIN_CORES=$PIN ./run.sh\" </dev/null >>run-mig.out 2>&1"
        echo "$(date +%H:%M:%S) progress: ${#DONE[@]}/24 migrated"
    fi
    sleep 30
done

echo "=== final pool state ==="
show | grep -E "riscv-qemu-navajo-([1-9]|1[0-9]|2[0-4]) " | sort -V
echo "=== root disk footprint (overlays should be tiny) ==="
ssh -o ConnectTimeout=60 "$HOST" "cd $DIR && du -ch riscv-qemu-navajo-*.qcow2 | tail -1; df -h $DIR | tail -1"
