#!/usr/bin/env bash
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "请用 root 运行此脚本"
  exit 1
fi

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$(cd "${SCRIPT_DIR}/.." && pwd)
TEMPLATE_DIR="${ROOT_DIR}/templates"

PICOSNITCH_VENV="${PICOSNITCH_VENV:-/opt/picosnitch-venv}"
PICOSNITCH_DASH_PORT="${PICOSNITCH_DASH_PORT:-5100}"
TRAFFIC_GUARD_WEB_PORT="${TRAFFIC_GUARD_WEB_PORT:-5101}"
TRAFFIC_GUARD_IFACE="${TRAFFIC_GUARD_IFACE:-eth0}"
TRAFFIC_GUARD_LIMIT_MIB="${TRAFFIC_GUARD_LIMIT_MIB:-1024}"
TRAFFIC_GUARD_ACTION="${TRAFFIC_GUARD_ACTION:-poweroff}"
TRAFFIC_GUARD_INTERVAL_SECONDS="${TRAFFIC_GUARD_INTERVAL_SECONDS:-10}"
ENABLE_GMAIL_NOTIFY="${ENABLE_GMAIL_NOTIFY:-0}"

MAIL_FROM="${MAIL_FROM:-}"
MAIL_TO="${MAIL_TO:-}"
SMTP_HOST="${SMTP_HOST:-smtp.gmail.com}"
SMTP_PORT="${SMTP_PORT:-587}"
SMTP_USER="${SMTP_USER:-}"
SMTP_PASS="${SMTP_PASS:-}"

log() {
  printf '[linuxnet] %s\n' "$*"
}

require_file() {
  local path="$1"
  if [ ! -f "$path" ]; then
    echo "缺少文件: $path"
    exit 1
  fi
}

install_packages() {
  log "安装系统依赖"
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    python3 \
    python3-venv \
    python3-pip \
    sqlite3 \
    msmtp-mta \
    ca-certificates
}

install_picosnitch() {
  log "安装 Picosnitch venv"
  if [ ! -d "$PICOSNITCH_VENV" ]; then
    python3 -m venv "$PICOSNITCH_VENV"
  fi
  "$PICOSNITCH_VENV/bin/pip" install --upgrade pip setuptools wheel
  "$PICOSNITCH_VENV/bin/pip" install --upgrade 'dash<3' 'plotly<6' picosnitch
}

patch_picosnitch_ui() {
  log "修补 Picosnitch Web 默认值与中文文案"
  local target
  target=$("$PICOSNITCH_VENV/bin/python" - <<'PY'
import site
paths = site.getsitepackages()
for base in paths:
    candidate = base + "/picosnitch.py"
    try:
        with open(candidate, "r", encoding="utf-8"):
            print(candidate)
            break
    except FileNotFoundError:
        continue
PY
)
  if [ -z "$target" ]; then
    echo "找不到 picosnitch.py"
    exit 1
  fi
  "$PICOSNITCH_VENV/bin/python" - "$target" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
replacements = [
    ("interval=5000", "interval=30000"),
    ('{"label": "Show Full Labels", "value": False}', '{"label": "显示完整标签", "value": False}'),
    ('options=[{"label": f"Select {dim_labels[x]}", "value": x} for x in all_dims]', 'options=[{"label": f"选择{dim_labels[x]}", "value": x} for x in all_dims]'),
    ('options=[{"label": f"Where {dim_labels[x]}", "value": x} for x in all_dims]', 'options=[{"label": f"筛选{dim_labels[x]}", "value": x} for x in all_dims]'),
    ('"exe": "Executable"', '"exe": "可执行文件"'),
]
for old, new in replacements:
    text = text.replace(old, new)

needle = """{"label": "自动刷新（10 分钟）", "value": 600},\n                    ],\n                    value=5,"""
if needle in text:
    text = text.replace(
        needle,
        """{"label": "自动刷新（10 分钟）", "value": 600},\n                    ],\n                    value=30,""",
    )

path.write_text(text, encoding="utf-8")
PY
}

write_picosnitch_services() {
  log "写入 Picosnitch systemd 服务"
  mkdir -p /etc/systemd/system

  cat > /etc/systemd/system/picosnitch.service <<EOF
[Unit]
Description=Picosnitch
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Restart=always
RestartSec=5
ExecStart=${PICOSNITCH_VENV}/bin/picosnitch start-no-daemon
PIDFile=/run/picosnitch.pid

[Install]
WantedBy=multi-user.target
EOF

  cat > /etc/systemd/system/picosnitch-dash.service <<EOF
[Unit]
Description=Picosnitch Dash Web UI
After=network-online.target picosnitch.service
Wants=network-online.target

[Service]
Type=simple
User=root
Environment=HOST=0.0.0.0
Environment=PORT=${PICOSNITCH_DASH_PORT}
ExecStart=${PICOSNITCH_VENV}/bin/picosnitch start-dash
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
}

write_traffic_guard_files() {
  log "写入 traffic-guard 脚本与配置"
  require_file "${TEMPLATE_DIR}/check-tx-shutdown.sh"
  require_file "${TEMPLATE_DIR}/send-shutdown-mail.sh"
  require_file "${TEMPLATE_DIR}/traffic-guard-web.py"

  install -d -m 755 /usr/local/lib/traffic-guard
  install -d -m 755 /var/lib/traffic-guard
  install -d -m 700 /etc/traffic-guard

  install -m 755 "${TEMPLATE_DIR}/check-tx-shutdown.sh" /usr/local/lib/traffic-guard/check-tx-shutdown.sh
  install -m 755 "${TEMPLATE_DIR}/send-shutdown-mail.sh" /usr/local/lib/traffic-guard/send-shutdown-mail.sh
  install -m 755 "${TEMPLATE_DIR}/traffic-guard-web.py" /usr/local/lib/traffic-guard/web.py

  cat > /etc/default/traffic-guard <<EOF
IFACE=${TRAFFIC_GUARD_IFACE}
LIMIT_BYTES=$((TRAFFIC_GUARD_LIMIT_MIB * 1024 * 1024))
ACTION=${TRAFFIC_GUARD_ACTION}
STATE_FILE=/var/lib/traffic-guard/${TRAFFIC_GUARD_IFACE}.baseline
EOF
}

write_traffic_guard_services() {
  log "写入 traffic-guard systemd 服务"
  cat > /etc/systemd/system/traffic-guard.service <<EOF
[Unit]
Description=Shut down the server when outbound traffic reaches the limit
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
EnvironmentFile=-/etc/default/traffic-guard
ExecStart=/usr/local/lib/traffic-guard/check-tx-shutdown.sh
EOF

  cat > /etc/systemd/system/traffic-guard.timer <<EOF
[Unit]
Description=Run outbound traffic guard every ${TRAFFIC_GUARD_INTERVAL_SECONDS} seconds

[Timer]
OnBootSec=${TRAFFIC_GUARD_INTERVAL_SECONDS}s
OnUnitActiveSec=${TRAFFIC_GUARD_INTERVAL_SECONDS}s
Unit=traffic-guard.service

[Install]
WantedBy=timers.target
EOF

  cat > /etc/systemd/system/traffic-guard-web.service <<EOF
[Unit]
Description=Traffic Guard Web UI
After=network-online.target traffic-guard.timer
Wants=network-online.target

[Service]
Type=simple
Environment=HOST=0.0.0.0
Environment=PORT=${TRAFFIC_GUARD_WEB_PORT}
ExecStart=/usr/bin/python3 /usr/local/lib/traffic-guard/web.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
}

write_mail_config() {
  if [ "$ENABLE_GMAIL_NOTIFY" != "1" ]; then
    log "跳过 Gmail 通知配置"
    return
  fi

  if [ -z "$MAIL_FROM" ] || [ -z "$MAIL_TO" ] || [ -z "$SMTP_USER" ] || [ -z "$SMTP_PASS" ]; then
    echo "启用 Gmail 通知时，必须提供 MAIL_FROM/MAIL_TO/SMTP_USER/SMTP_PASS"
    exit 1
  fi

  log "写入 Gmail 通知配置"
  cat > /etc/traffic-guard/gmail-notify.conf <<EOF
MAIL_FROM=${MAIL_FROM}
MAIL_TO=${MAIL_TO}
SMTP_HOST=${SMTP_HOST}
SMTP_PORT=${SMTP_PORT}
SMTP_USER=${SMTP_USER}
SMTP_PASS=${SMTP_PASS}
EOF
  chmod 600 /etc/traffic-guard/gmail-notify.conf
}

enable_services() {
  log "重载并启动服务"
  systemctl daemon-reload
  systemctl enable --now picosnitch.service
  systemctl enable --now picosnitch-dash.service
  systemctl enable --now traffic-guard.timer
  systemctl enable --now traffic-guard-web.service
}

verify() {
  log "验证服务状态"
  systemctl --no-pager --full status picosnitch.service picosnitch-dash.service traffic-guard.timer traffic-guard-web.service || true
  echo
  echo "Picosnitch Web: http://<server-ip>:${PICOSNITCH_DASH_PORT}"
  echo "Traffic Guard Web: http://<server-ip>:${TRAFFIC_GUARD_WEB_PORT}"
}

install_packages
install_picosnitch
patch_picosnitch_ui
write_picosnitch_services
write_traffic_guard_files
write_traffic_guard_services
write_mail_config
enable_services
verify
