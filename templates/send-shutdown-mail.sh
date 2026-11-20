#!/usr/bin/env bash
set -euo pipefail

CONF="/etc/traffic-guard/gmail-notify.conf"
DB_PATH="/root/.config/picosnitch/snitch.db"

[ -f "$CONF" ] || exit 0

# shellcheck disable=SC1090
source "$CONF"

used_bytes="${2:-0}"
limit_bytes="${3:-0}"
warn_percent="${4:-0}"
DRY_RUN="${DRY_RUN:-0}"

# 兼容旧调用方式：只有一个数字参数时视为关机通知
case "${1:-}" in
  warning|shutdown) event="$1" ;;
  *)
    event="shutdown"
    used_bytes="${1:-0}"
    limit_bytes="${2:-0}"
    ;;
esac

format_bytes() {
  local value="$1"
  local units=(B KiB MiB GiB TiB)
  local idx=0
  local rem=0
  while [ "$value" -ge 1024 ] && [ "$idx" -lt 4 ]; do
    rem=$((value % 1024))
    value=$((value / 1024))
    idx=$((idx + 1))
  done
  if [ "$idx" -eq 0 ]; then
    printf '%s %s' "$value" "${units[$idx]}"
  else
    printf '%s.%02d %s' "$value" $(((rem * 100) / 1024)) "${units[$idx]}"
  fi
}

if [ "$event" = "warning" ]; then
  subject="流量预警：已用 $(format_bytes "$used_bytes")（${warn_percent}%），阈值 $(format_bytes "$limit_bytes")"
else
  subject="服务器关机：已用流量 $(format_bytes "$used_bytes")，阈值 $(format_bytes "$limit_bytes")"
fi
body_file=$(mktemp)
mail_config=$(mktemp)

cleanup() {
  rm -f "$body_file" "$mail_config"
}
trap cleanup EXIT

python3 - "$DB_PATH" > "$body_file" <<'PY'
import sqlite3
import sys
from pathlib import Path


def fmt(value: int) -> str:
    units = ["B", "KiB", "MiB", "GiB", "TiB"]
    size = float(value)
    for unit in units:
        if size < 1024 or unit == units[-1]:
            return f"{size:.2f} {unit}"
        size /= 1024
    return f"{value} B"


path = Path(sys.argv[1])
if not path.exists():
    print("上传前5")
    print("1. 无法读取 Picosnitch 数据库")
    print()
    print("下载前5")
    print("1. 无法读取 Picosnitch 数据库")
    raise SystemExit(0)

conn = sqlite3.connect(path)
cur = conn.cursor()
queries = {
    "上传前5": """
        SELECT COALESCE(NULLIF(exe, ''), '[未知程序]') AS exe, SUM(send) AS total
        FROM connections
        GROUP BY exe
        ORDER BY total DESC, exe ASC
        LIMIT 5
    """,
    "下载前5": """
        SELECT COALESCE(NULLIF(exe, ''), '[未知程序]') AS exe, SUM(recv) AS total
        FROM connections
        GROUP BY exe
        ORDER BY total DESC, exe ASC
        LIMIT 5
    """,
}
for idx, (title, query) in enumerate(queries.items()):
    print(title)
    rows = cur.execute(query).fetchall()
    if not rows:
        print("1. 暂无数据")
    else:
        for i, (exe, total) in enumerate(rows, 1):
            print(f"{i}. {exe} {fmt(int(total or 0))}")
    if idx == 0:
        print()
conn.close()
PY

cat > "$mail_config" <<MSMTP
account default
host ${SMTP_HOST}
port ${SMTP_PORT}
auth on
tls on
tls_starttls on
tls_trust_file /etc/ssl/certs/ca-certificates.crt
from ${MAIL_FROM}
user ${SMTP_USER}
password ${SMTP_PASS}
logfile /var/log/traffic-guard-msmtp.log
MSMTP

chmod 600 "$mail_config"

if [ "$DRY_RUN" = "1" ]; then
  printf 'Subject: %s\n\n' "$subject"
  cat "$body_file"
  exit 0
fi

{
  printf 'From: %s\n' "$MAIL_FROM"
  printf 'To: %s\n' "$MAIL_TO"
  printf 'Subject: %s\n' "$subject"
  printf '\n'
  cat "$body_file"
} | msmtp --file="$mail_config" "$MAIL_TO" || true
