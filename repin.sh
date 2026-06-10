#!/bin/bash
# Restart a worker VM in place, keeping its obuilder disk, so run.sh re-launches
# it at the current SMP/MEM and re-pins it. Use to change vCPU/RAM sizing of a
# running worker without rebuilding. Run on the worker host.
#
# Usage: PIN_CORES=4-63,68-127 ./repin.sh <worker-name>
set -e

name=$1
[ -n "$name" ] || { echo "usage: $0 <worker-name>"; exit 1; }
cd "$(dirname "$0")"

pid=$(pgrep -f "file=${name}.qcow2,if=virtio" || true)
if [ -n "$pid" ]; then
    echo "stopping ${name} (pid ${pid})"
    kill "$pid" 2>/dev/null || true
    for _ in $(seq 1 60); do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
    kill -9 "$pid" 2>/dev/null || true
    sleep 2
fi

# run.sh re-launches any stopped worker at the current SMP/MEM, pinned to free cores.
setsid bash -c "PIN_CORES='${PIN_CORES:-}' ./run.sh" </dev/null >>repin.out 2>&1
echo "${name}: restarted via run.sh"
