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
. "$(dirname "$0")/lib-stopvm.sh"

# Clean guest poweroff (avoids corrupting docker/BuildKit), then run.sh relaunches.
stop_vm "$name"

# run.sh re-launches any stopped worker at the current SMP/MEM, pinned to free cores.
setsid bash -c "PIN_CORES='${PIN_CORES:-}' ./run.sh" </dev/null >>repin.out 2>&1
echo "${name}: restarted via run.sh"
