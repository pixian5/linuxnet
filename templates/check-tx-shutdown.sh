#!/usr/bin/env bash
set -euo pipefail

IFACE="${IFACE:-eth0}"
LIMIT_BYTES="${LIMIT_BYTES:-1073741824}"
ACTION="${ACTION:-poweroff}"
STATE_FILE="${STATE_FILE:-/var/lib/traffic-guard/${IFACE}.baseline}"
TX_FILE="/sys/class/net/${IFACE}/statistics/tx_bytes"

if [ ! -r "$TX_FILE" ]; then
  logger -t traffic-guard "Interface ${IFACE} is unavailable; skipping check"
  exit 0
fi

current=$(cat "$TX_FILE")

if [ ! -f "$STATE_FILE" ]; then
  printf "%s\n" "$current" > "$STATE_FILE"
  logger -t traffic-guard "Initialized baseline for ${IFACE} at ${current} bytes"
  exit 0
fi

baseline=$(cat "$STATE_FILE")

if [ "$current" -lt "$baseline" ]; then
  printf "%s\n" "$current" > "$STATE_FILE"
  logger -t traffic-guard "Reset baseline for ${IFACE} after counter rollback to ${current} bytes"
  exit 0
fi

used=$((current - baseline))

if [ "$used" -lt "$LIMIT_BYTES" ]; then
  exit 0
fi

logger -t traffic-guard "Outbound traffic on ${IFACE} reached ${used} bytes (limit ${LIMIT_BYTES}); action=${ACTION}"
/usr/local/lib/traffic-guard/send-shutdown-mail.sh "$used" "$LIMIT_BYTES" || true

case "$ACTION" in
  poweroff)
    /sbin/poweroff
    ;;
  halt)
    /sbin/halt
    ;;
  *)
    logger -t traffic-guard "Unknown action ${ACTION}; refusing to continue"
    exit 1
    ;;
esac
