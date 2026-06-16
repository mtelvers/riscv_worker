# Shared helper to stop a worker VM cleanly. Source this from a script that
# runs on the worker host (as root): . "$(dirname "$0")/lib-stopvm.sh"
#
# The VMs run with -machine acpi=off, so killing the QEMU process is an unclean
# power-cut: the guest never flushes and docker/BuildKit's snapshotter can be
# left corrupt ("parent snapshot does not exist", "lease not found"), which
# makes every later build fail. So we ssh into the guest and power it off
# cleanly first - systemd stops docker (flushing its state) and the kernel
# halts, at which point QEMU exits on its own (the same way the cloud-init bake
# ends with `poweroff` and QEMU returns). Only if that does not bring QEMU down
# do we fall back to SIGTERM then SIGKILL.
#
# Override the guest credentials / timeout if your deployment differs:
GUEST_SSH_KEY=${GUEST_SSH_KEY:-/tmp/alpha_key}
GUEST_SSH_USER=${GUEST_SSH_USER:-opam}
# Emulated (TCG) guest shutdown is slow: measured ~240s to fully halt and have
# QEMU exit. Wait comfortably past that before falling back to a hard kill.
GUEST_POWEROFF_WAIT=${GUEST_POWEROFF_WAIT:-360}

# stop_vm <worker-name>
stop_vm() {
    local name=$1
    local pid port i
    # The ".qcow2," boundary stops navajo-1 from matching navajo-10/11.
    pid=$(pgrep -f "file=${name}.qcow2,if=virtio" || true)
    [ -n "$pid" ] || return 0

    # Forwarded guest SSH port from the QEMU command line (hostfwd=tcp::PORT-:22).
    port=$(tr '\0' ' ' < /proc/"$pid"/cmdline 2>/dev/null \
        | grep -oE 'hostfwd=tcp::[0-9]+-:22' | grep -oE '[0-9]+' | head -1)

    if [ -n "$port" ] && [ -r "$GUEST_SSH_KEY" ]; then
        echo "${name}: clean guest poweroff (ssh :${port}, up to ${GUEST_POWEROFF_WAIT}s)"
        # Stop docker.socket first so it cannot re-trigger the service, then
        # docker.service (this flushes containerd/BuildKit state before halt),
        # then power off. The ssh call blocks until docker has stopped.
        ssh -p "$port" -i "$GUEST_SSH_KEY" \
            -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -o ConnectTimeout=15 -o BatchMode=yes "${GUEST_SSH_USER}@localhost" \
            "sudo systemctl stop docker.socket docker.service 2>/dev/null; sudo poweroff" 2>/dev/null || true
        # QEMU exits when the guest halts; emulated shutdown can take a while.
        for i in $(seq 1 "$GUEST_POWEROFF_WAIT"); do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
    else
        echo "${name}: WARNING - no guest ssh (port='${port}', key='${GUEST_SSH_KEY}'); killing QEMU directly"
    fi

    # Fallback: clean poweroff unavailable or did not bring QEMU down.
    if kill -0 "$pid" 2>/dev/null; then
        echo "${name}: forcing stop (pid ${pid})"
        kill "$pid" 2>/dev/null || true
        for i in $(seq 1 60); do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
        kill -9 "$pid" 2>/dev/null || true
    fi
    sleep 2
}
