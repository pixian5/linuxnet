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
PICOSNITCH_VERSION="1.0.3"
PICOSNITCH_DASH_VERSION="2.18.2"
PLOTLY_VERSION="5.24.1"
# pandas 2.2.3 是最后一个同时提供 cp312 wheel 的稳定版本之一；Ubuntu 24.04 自带 Python 3.12，
# 旧值 2.0.3 没有 cp312 wheel，会退化为源码编译并缺少编译环境而失败。
PANDAS_VERSION="2.2.3"
PICOSNITCH_DASH_HOST="${PICOSNITCH_DASH_HOST:-127.0.0.1}"
PICOSNITCH_DASH_PORT="${PICOSNITCH_DASH_PORT:-5100}"
TRAFFIC_GUARD_WEB_HOST="${TRAFFIC_GUARD_WEB_HOST:-127.0.0.1}"
TRAFFIC_GUARD_WEB_PORT="${TRAFFIC_GUARD_WEB_PORT:-5101}"
TRAFFIC_GUARD_IFACE="${TRAFFIC_GUARD_IFACE:-eth0}"
TRAFFIC_GUARD_LIMIT_MIB="${TRAFFIC_GUARD_LIMIT_MIB:-1024}"
TRAFFIC_GUARD_ACTION="${TRAFFIC_GUARD_ACTION:-poweroff}"
TRAFFIC_GUARD_WARN_PERCENT="${TRAFFIC_GUARD_WARN_PERCENT:-80}"
TRAFFIC_GUARD_INTERVAL_SECONDS="${TRAFFIC_GUARD_INTERVAL_SECONDS:-10}"
ENABLE_GMAIL_NOTIFY="${ENABLE_GMAIL_NOTIFY:-0}"

MAIL_FROM="${MAIL_FROM:-}"
MAIL_TO="${MAIL_TO:-}"
SMTP_HOST="${SMTP_HOST:-smtp.gmail.com}"
SMTP_PORT="${SMTP_PORT:-587}"
SMTP_USER="${SMTP_USER:-}"
SMTP_PASS="${SMTP_PASS:-}"

validate_inputs() {
  [[ "$PICOSNITCH_VENV" =~ ^/[A-Za-z0-9_./-]+$ ]] || {
    echo "PICOSNITCH_VENV 必须是安全的绝对路径"
    exit 1
  }
  [[ "$PICOSNITCH_DASH_HOST" =~ ^(127\.0\.0\.1|::1)$ ]] || {
    echo "PICOSNITCH_DASH_HOST 必须是 127.0.0.1 或 ::1"
    exit 1
  }
  [[ "$TRAFFIC_GUARD_WEB_HOST" =~ ^(127\.0\.0\.1|::1)$ ]] || {
    echo "TRAFFIC_GUARD_WEB_HOST 必须是 127.0.0.1 或 ::1"
    exit 1
  }
  [[ "$PICOSNITCH_DASH_PORT" =~ ^[0-9]+$ && "$PICOSNITCH_DASH_PORT" -ge 1 && "$PICOSNITCH_DASH_PORT" -le 65535 ]] || { echo "PICOSNITCH_DASH_PORT 无效"; exit 1; }
  [[ "$TRAFFIC_GUARD_WEB_PORT" =~ ^[0-9]+$ && "$TRAFFIC_GUARD_WEB_PORT" -ge 1 && "$TRAFFIC_GUARD_WEB_PORT" -le 65535 ]] || { echo "TRAFFIC_GUARD_WEB_PORT 无效"; exit 1; }
  [[ "$TRAFFIC_GUARD_IFACE" =~ ^[A-Za-z0-9_.:-]+$ ]] || { echo "TRAFFIC_GUARD_IFACE 包含非法字符"; exit 1; }
  [[ "$TRAFFIC_GUARD_LIMIT_MIB" =~ ^[1-9][0-9]*$ && "$TRAFFIC_GUARD_LIMIT_MIB" -le 8796093022207 ]] || { echo "TRAFFIC_GUARD_LIMIT_MIB 必须是有效正整数"; exit 1; }
  [[ "$TRAFFIC_GUARD_INTERVAL_SECONDS" =~ ^[1-9][0-9]*$ ]] || { echo "TRAFFIC_GUARD_INTERVAL_SECONDS 必须是正整数"; exit 1; }
  [[ "$TRAFFIC_GUARD_WARN_PERCENT" =~ ^[0-9]{1,2}$ && "$TRAFFIC_GUARD_WARN_PERCENT" -le 99 ]] || { echo "TRAFFIC_GUARD_WARN_PERCENT 必须是 0-99 的整数（0 表示关闭预警）"; exit 1; }
  # none 表示只发邮件不关机，便于先观察一段时间再启用关机
  case "$TRAFFIC_GUARD_ACTION" in poweroff|halt|none) ;; *) echo "TRAFFIC_GUARD_ACTION 只能是 poweroff、halt 或 none"; exit 1 ;; esac
}

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
    bpfcc-tools \
    python3-bpfcc \
    sqlite3 \
    msmtp-mta \
    ca-certificates
}

install_picosnitch() {
  log "安装 Picosnitch venv"
  python3 -m venv --system-site-packages "$PICOSNITCH_VENV"
  "$PICOSNITCH_VENV/bin/pip" install --upgrade pip setuptools wheel
  "$PICOSNITCH_VENV/bin/pip" install --upgrade \
    "dash==${PICOSNITCH_DASH_VERSION}" \
    "plotly==${PLOTLY_VERSION}" \
    "pandas==${PANDAS_VERSION}" \
    psutil
  # 强制重装 picosnitch 本体，把上一次部署打过的补丁覆盖回上游原始文件。
  # 否则补丁脚本会因为目标字符串已被替换而报“命中 0 次”，导致二次部署失败。
  # 注意必须 --no-deps，否则会把 dash/pandas/plotly 一起拖着重装；因此 psutil 在上一条命令显式安装。
  "$PICOSNITCH_VENV/bin/pip" install --upgrade --force-reinstall --no-deps \
    "picosnitch==${PICOSNITCH_VERSION}"
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
    ("interval=10000", "interval=30000", 1),
    ('{"label": "Show Full Labels", "value": False}', '{"label": "显示完整标签", "value": False}', 1),
    ('options=[{"label": f"Select {dim_labels[x]}", "value": x} for x in all_dims]', 'options=[{"label": f"选择{dim_labels[x]}", "value": x} for x in all_dims]', 1),
    ('options=[{"label": f"Where {dim_labels[x]}", "value": x} for x in all_dims]', 'options=[{"label": f"筛选{dim_labels[x]}", "value": x} for x in all_dims]', 1),
    ('"exe": "Executable"', '"exe": "可执行文件"', 1),
    ('{"label": "Auto-Refresh (10 minutes)", "value": 600},\n                    ],\n                    value=0,', '{"label": "Auto-Refresh (10 minutes)", "value": 600},\n                    ],\n                    value=30,', 1),
]
changed = False
for old, new, expected in replacements:
    old_count = text.count(old)
    new_count = text.count(new)
    if old_count == expected:
        text = text.replace(old, new)
        changed = True
        continue
    # 已经打过补丁：目标字符串为 0 次且替换后字符串正好为期望次数，视为幂等通过
    if old_count == 0 and new_count >= expected:
        continue
    raise SystemExit(f"Picosnitch {path.name} 补丁不兼容：期望命中 {expected} 次，实际 {old_count} 次：{old[:60]}")

if changed:
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
Environment=HOST=${PICOSNITCH_DASH_HOST}
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

  if [ -z "${TRAFFIC_GUARD_WEB_TOKEN:-}" ] && [ -s /etc/traffic-guard/web-token ]; then
    TRAFFIC_GUARD_WEB_TOKEN=$(cat /etc/traffic-guard/web-token)
  elif [ -z "${TRAFFIC_GUARD_WEB_TOKEN:-}" ]; then
    TRAFFIC_GUARD_WEB_TOKEN=$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')
  fi
  printf '%s\n' "$TRAFFIC_GUARD_WEB_TOKEN" > /etc/traffic-guard/web-token
  chmod 600 /etc/traffic-guard/web-token

  cat > /etc/default/traffic-guard <<EOF
IFACE=${TRAFFIC_GUARD_IFACE}
LIMIT_BYTES=$((TRAFFIC_GUARD_LIMIT_MIB * 1024 * 1024))
ACTION=${TRAFFIC_GUARD_ACTION}
WARN_PERCENT=${TRAFFIC_GUARD_WARN_PERCENT}
STATE_FILE=/var/lib/traffic-guard/${TRAFFIC_GUARD_IFACE}.baseline
WEB_TOKEN_FILE=/etc/traffic-guard/web-token
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
User=root
Environment=HOST=${TRAFFIC_GUARD_WEB_HOST}
Environment=PORT=${TRAFFIC_GUARD_WEB_PORT}
ExecStart=/usr/bin/python3 /usr/local/lib/traffic-guard/web.py
Restart=always
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true

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
  log "重载并重启服务"
  systemctl daemon-reload
  systemctl enable picosnitch.service picosnitch-dash.service traffic-guard.timer traffic-guard-web.service
  systemctl restart picosnitch.service
  systemctl restart picosnitch-dash.service
  systemctl restart traffic-guard.timer
  systemctl restart traffic-guard-web.service
}

verify() {
  log "验证服务状态"
  systemctl is-active --quiet picosnitch.service
  systemctl is-active --quiet picosnitch-dash.service
  systemctl is-active --quiet traffic-guard.timer
  systemctl is-active --quiet traffic-guard-web.service
  /usr/bin/python3 - "$PICOSNITCH_DASH_HOST" "$PICOSNITCH_DASH_PORT" "$TRAFFIC_GUARD_WEB_HOST" "$TRAFFIC_GUARD_WEB_PORT" <<'PY'
import base64
import sys
import time
from urllib.request import Request, urlopen

pico_host, pico_port, guard_host, guard_port = sys.argv[1:]
token = open("/etc/traffic-guard/web-token", encoding="utf-8").read().strip()
authorization = "Basic " + base64.b64encode(("admin:" + token).encode()).decode()

def url(host, port):
    display_host = f"[{host}]" if ":" in host else host
    return f"http://{display_host}:{port}/"

checks = [
    ("Picosnitch Web", Request(url(pico_host, pico_port))),
    ("Traffic Guard Web", Request(url(guard_host, guard_port), headers={"Authorization": authorization})),
]
for name, request in checks:
    last_error = None
    for _ in range(10):
        try:
            with urlopen(request, timeout=3) as response:
                if response.status == 200:
                    break
                last_error = f"HTTP {response.status}"
        except Exception as exc:
            last_error = str(exc)
        time.sleep(1)
    else:
        raise SystemExit(f"{name} 健康检查失败：{last_error}")
PY
  echo
  echo "Picosnitch Web: http://${PICOSNITCH_DASH_HOST}:${PICOSNITCH_DASH_PORT}"
  echo "Traffic Guard Web: http://${TRAFFIC_GUARD_WEB_HOST}:${TRAFFIC_GUARD_WEB_PORT}（Basic 用户名：admin，密码见 /etc/traffic-guard/web-token）"
}

validate_inputs
install_packages
install_picosnitch
patch_picosnitch_ui
write_picosnitch_services
write_traffic_guard_files
write_traffic_guard_services
write_mail_config
enable_services
verify
