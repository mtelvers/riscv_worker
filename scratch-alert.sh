#!/bin/bash
# Alert to Slack when /local/scratch on this worker host is >= THRESH% full.
# Runs from root cron (silent below the threshold). The Slack webhook URL is read
# from a root-only file so it never lives in this script or in git:
#   echo 'https://hooks.slack.com/services/...' > /usr/local/etc/scratch-alert.url
#   chmod 600 /usr/local/etc/scratch-alert.url
# Install: copy to /usr/local/bin/scratch-alert.sh (0755); cron: 0 8 * * *
set -u
THRESH=${THRESH:-85}
URLFILE=${URLFILE:-/usr/local/etc/scratch-alert.url}
DIR=/local/scratch/riscv_worker

use=$(df --output=pcent /local/scratch 2>/dev/null | tail -1 | tr -dc '0-9')
[ -n "$use" ] || exit 0
[ "$use" -ge "$THRESH" ] || exit 0
[ -r "$URLFILE" ] || { echo "no webhook url file: $URLFILE" >&2; exit 1; }
url=$(cat "$URLFILE")

dfline=$(df -h /local/scratch | tail -1 | tr -s ' ')
ob=$(du -ch "$DIR"/*-obuilder.qcow2 2>/dev/null | tail -1 | cut -f1)
dk=$(du -ch "$DIR"/*-docker.qcow2 2>/dev/null | tail -1 | cut -f1)
overlays=$(ls "$DIR"/*.qcow2 2>/dev/null | grep -vE '(-obuilder|-docker|/base)\.qcow2$')
ov=$([ -n "$overlays" ] && du -ch $overlays 2>/dev/null | tail -1 | cut -f1 || echo 0)

msg="WARNING: $(hostname) /local/scratch at ${use}% -- ${dfline} | obuilder ${ob}, docker ${dk}, overlays ${ov} (30 emulated riscv64 workers; prune-bounded)"
curl -s -H "Content-type: application/json" -d "{ \"text\": \"${msg}\" }" -X POST "$url" >/dev/null
