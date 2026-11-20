#!/usr/bin/env bash
set -euo pipefail

CONF="/etc/traffic-guard/gmail-notify.conf"
# picosnitch 2.x 的数据库位置；1.x 是 /root/.config/picosnitch/snitch.db
DB_PATH="${DB_PATH:-/var/lib/picosnitch/picosnitch.db}"

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


def has_table(name):
    row = cur.execute(
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", (name,)
    ).fetchone()
    return row is not None


def columns(table):
    return {r[1] for r in cur.execute(f"PRAGMA table_info({table})").fetchall()}


# picosnitch 2.x 把 exe 规范化到 executables 表，connections 只存 exe_id；
# 1.x 直接在 connections 里有 exe 列。两套 schema 都要能读。
if "exe" in columns("connections"):
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
elif has_table("executables") and "exe_id" in columns("connections"):
    queries = {
        "上传前5": """
            SELECT COALESCE(NULLIF(e.exe, ''), NULLIF(e.name, ''), '[未知程序]') AS exe,
                   SUM(c.send) AS total
            FROM connections c
            JOIN executables e ON e.id = c.exe_id
            GROUP BY exe
            ORDER BY total DESC, exe ASC
            LIMIT 5
        """,
        "下载前5": """
            SELECT COALESCE(NULLIF(e.exe, ''), NULLIF(e.name, ''), '[未知程序]') AS exe,
                   SUM(c.recv) AS total
            FROM connections c
            JOIN executables e ON e.id = c.exe_id
            GROUP BY exe
            ORDER BY total DESC, exe ASC
            LIMIT 5
        """,
    }
else:
    queries = {}
if not queries:
    print("上传前5")
    print("1. 数据库结构无法识别")
    print()
    print("下载前5")
    print("1. 数据库结构无法识别")
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

# 465 端口用隐式 TLS（tls_starttls off），587 用 STARTTLS（on）。
# 配置里没写 SMTP_STARTTLS 时按端口推断，兼容旧配置文件。
if [ -z "${SMTP_STARTTLS:-}" ]; then
  if [ "${SMTP_PORT}" = "465" ]; then
    SMTP_STARTTLS="off"
  else
    SMTP_STARTTLS="on"
  fi
fi

cat > "$mail_config" <<MSMTP
account default
host ${SMTP_HOST}
port ${SMTP_PORT}
auth on
tls on
tls_starttls ${SMTP_STARTTLS}
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

send_mail() {
  {
    printf 'From: %s\n' "$MAIL_FROM"
    printf 'To: %s\n' "$MAIL_TO"
    printf 'Subject: %s\n' "$subject"
    printf '\n'
    cat "$body_file"
  } | msmtp --file="$mail_config" "$MAIL_TO"
}

# 邮件商（如 189）短时间连发会返回 535，换个说法就是限流，等一会儿就好。
# 因此失败后延迟重试，而不是直接放弃——关机通知丢失的代价比多等 30 秒大得多。
MAIL_RETRY_DELAY="${MAIL_RETRY_DELAY:-30}"
MAIL_MAX_ATTEMPTS="${MAIL_MAX_ATTEMPTS:-3}"
[[ "$MAIL_RETRY_DELAY" =~ ^[0-9]+$ ]] || MAIL_RETRY_DELAY=30
[[ "$MAIL_MAX_ATTEMPTS" =~ ^[1-9][0-9]*$ ]] || MAIL_MAX_ATTEMPTS=3

attempt=1
while :; do
  if send_mail; then
    if [ "$attempt" -gt 1 ]; then
      logger -t traffic-guard "邮件发送成功（第 ${attempt} 次尝试）"
    fi
    exit 0
  fi
  if [ "$attempt" -ge "$MAIL_MAX_ATTEMPTS" ]; then
    # 写日志而不是静默忽略：调用方用 || true 兜底，否则失败完全不可见
    logger -t traffic-guard "邮件发送失败，已尝试 ${attempt} 次，放弃（详见 /var/log/traffic-guard-msmtp.log）"
    exit 1
  fi
  logger -t traffic-guard "邮件发送失败（第 ${attempt} 次），${MAIL_RETRY_DELAY} 秒后重试"
  sleep "$MAIL_RETRY_DELAY"
  attempt=$((attempt + 1))
done
