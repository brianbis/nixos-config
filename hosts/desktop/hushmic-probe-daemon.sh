#!/usr/bin/env bash
# hushmic probe daemon: samples host mic state every 2s (append-only ring).
# Runs on the host as root. Start: nohup /etc/nixos/hosts/desktop/hushmic-probe-daemon.sh &
# Stop: pkill -f hushmic-probe-daemon
set -euo pipefail
probe=/etc/nixos/hosts/desktop/hushmic-probe.sh
while :; do
  "$probe"
  cat /var/lib/crush-system/hushmic-probe/latest >> /var/lib/crush-system/hushmic-probe/ring
  sleep 2
done