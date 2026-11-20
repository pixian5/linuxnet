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
# picosnitch 2.x 使用预编译 CO-RE BPF 对象（picosnitch/bpf/*.bpf.o），无需运行时编译。
# 1.x 会在运行时用系统 BCC 编译 BPF 源码，而 Ubuntu 24.04 只有 BCC 0.29，
# 在 6.14+/7.0 内核上因缺少 BPF_LOAD_ACQ / BPF_F_CPU 等新常量必然失败。
PICOSNITCH_VERSION="2.2.1"
PICOSNITCH_WEB_HOST="${PICOSNITCH_WEB_HOST:-127.0.0.1}"
PICOSNITCH_WEB_PORT="${PICOSNITCH_WEB_PORT:-5100}"
PICOSNITCH_DB="/var/lib/picosnitch/picosnitch.db"
PICOSNITCH_CONFIG_DIR="/etc/picosnitch"
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
  [[ "$PICOSNITCH_WEB_HOST" =~ ^(127\.0\.0\.1|::1)$ ]] || {
    echo "PICOSNITCH_WEB_HOST 必须是 127.0.0.1 或 ::1"
    exit 1
  }
  [[ "$TRAFFIC_GUARD_WEB_HOST" =~ ^(127\.0\.0\.1|::1)$ ]] || {
    echo "TRAFFIC_GUARD_WEB_HOST 必须是 127.0.0.1 或 ::1"
    exit 1
  }
  [[ "$PICOSNITCH_WEB_PORT" =~ ^[0-9]+$ && "$PICOSNITCH_WEB_PORT" -ge 1 && "$PICOSNITCH_WEB_PORT" -le 65535 ]] || { echo "PICOSNITCH_WEB_PORT 无效"; exit 1; }
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

# 云镜像的 unattended-upgrades 常会持锁，直接 apt 会失败。
# 注意不能用 pgrep 判断：unattended-upgrade-shutdown 是常驻守护进程，并不持锁，会造成误报空等。
# 这里改为直接调用 apt，仅当报错文本是锁冲突时才等待重试，最多 10 分钟。
apt_with_lock_retry() {
  local waited=0 output
  while :; do
    if output=$(DEBIAN_FRONTEND=noninteractive apt-get "$@" 2>&1); then
      printf '%s\n' "$output"
      return 0
    fi
    printf '%s\n' "$output" >&2
    if printf '%s' "$output" | grep -q "Could not get lock\|Unable to acquire the dpkg frontend lock"; then
      if [ "$waited" -ge 600 ]; then
        echo "等待 dpkg 锁超时（600 秒），请检查 unattended-upgrades 是否卡住"
        return 1
      fi
      if [ "$waited" -eq 0 ]; then
        log "dpkg 被其它进程占用（通常是 unattended-upgrades），等待其完成…"
      fi
      sleep 10
      waited=$((waited + 10))
      continue
    fi
    return 1
  done
}

install_packages() {
  log "安装系统依赖"
  apt_with_lock_retry update
  # 不再需要 bpfcc-tools：picosnitch 2.x 使用预编译 CO-RE 对象，只用内核/libbpf，不需要 BCC
  apt_with_lock_retry install -y \
    python3 \
    python3-venv \
    python3-pip \
    sqlite3 \
    msmtp-mta \
    ca-certificates
}

install_picosnitch() {
  log "安装 Picosnitch venv"
  python3 -m venv "$PICOSNITCH_VENV"
  "$PICOSNITCH_VENV/bin/pip" install --upgrade pip setuptools wheel
  # 2.x 是预编译 BPF 包，依赖由 pip 自动解析；--force-reinstall 保证可重复部署
  "$PICOSNITCH_VENV/bin/pip" install --upgrade --force-reinstall \
    "picosnitch==${PICOSNITCH_VERSION}"
}

configure_picosnitch() {
  log "写入 Picosnitch 配置（关闭桌面通知与 GeoIP 下载，服务器无需这些）"
  install -d -m 755 "$PICOSNITCH_CONFIG_DIR"
  # 2.x 首次运行会写出默认 config.toml；这里直接写好，避免依赖首次启动时机。
  # 只覆盖我们关心的项，其余用上游默认值。
  cat > "${PICOSNITCH_CONFIG_DIR}/config.toml" <<'EOF'
[database]
enabled = true
retention_days = 30
write_limit_seconds = 10
text_log = false

[data]
owner = "root"
group = "root"
mode = "0644"

[log]
addresses = true
commands = true
ports = true
ignore_ports = []
ignore_domains = []
ignore_ips = []
ignore_sha256 = []

[desktop]
user = ""
notifications = false
geoip_lookup = false

[monitoring]
every_exe = false
perf_ring_buffer_pages = 256
conn_map_max_entries = 65536
EOF
  chmod 600 "${PICOSNITCH_CONFIG_DIR}/config.toml"
}

write_picosnitch_services() {
  log "写入 Picosnitch systemd 服务"
  mkdir -p /etc/systemd/system

  # 采用上游 2.x 官方单元的关键项（FHS 目录、LimitMEMLOCK、加固），确保 BPF 环形缓冲区能正常映射
  cat > /etc/systemd/system/picosnitch.service <<EOF
[Unit]
Description=Picosnitch
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Restart=always
RestartSec=5
ExecStart=${PICOSNITCH_VENV}/bin/python3 -m picosnitch start-no-daemon
PIDFile=/run/picosnitch/picosnitch.pid

RuntimeDirectory=picosnitch
StateDirectory=picosnitch
LogsDirectory=picosnitch
CacheDirectory=picosnitch
ConfigurationDirectory=picosnitch

# libbpf 需要 mmap 约 16 MiB 的 per-cpu perf ring buffer，默认 8 MiB 上限会失败
LimitMEMLOCK=infinity

ProtectHome=read-only
ProtectSystem=strict
ReadWritePaths=/var/lib/picosnitch /var/log/picosnitch /run/picosnitch /var/cache/picosnitch
PrivateTmp=yes
NoNewPrivileges=yes
CapabilityBoundingSet=CAP_BPF CAP_DAC_OVERRIDE CAP_DAC_READ_SEARCH CAP_NET_ADMIN CAP_PERFMON CAP_SETGID CAP_SETUID CAP_SYS_ADMIN CAP_SYS_PTRACE
ProtectKernelModules=yes
ProtectKernelLogs=yes
ProtectControlGroups=yes
ProtectClock=yes
RestrictRealtime=yes
LockPersonality=yes
RestrictSUIDSGID=yes

[Install]
WantedBy=multi-user.target
EOF

  # 2.x 的 webui 是独立前台进程，用 PICOSNITCH_HOST/PORT 控制监听地址
  cat > /etc/systemd/system/picosnitch-dash.service <<EOF
[Unit]
Description=Picosnitch Web UI
After=network-online.target picosnitch.service
Wants=network-online.target

[Service]
Type=simple
User=root
Environment=PICOSNITCH_HOST=${PICOSNITCH_WEB_HOST}
Environment=PICOSNITCH_PORT=${PICOSNITCH_WEB_PORT}
ExecStart=${PICOSNITCH_VENV}/bin/picosnitch webui
Restart=always
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true

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
  /usr/bin/python3 - "$PICOSNITCH_WEB_HOST" "$PICOSNITCH_WEB_PORT" "$TRAFFIC_GUARD_WEB_HOST" "$TRAFFIC_GUARD_WEB_PORT" <<'PY'
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
    for _ in range(20):
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
  # 确认 picosnitch 真的加载了 BPF 并写入采集数据，避免“服务 active 但实际没工作”
  local deadline=$((SECONDS + 60))
  while [ "$SECONDS" -lt "$deadline" ]; do
    if [ -s "$PICOSNITCH_DB" ] && [ "$(sqlite3 "$PICOSNITCH_DB" 'SELECT count(*) FROM connections;' 2>/dev/null || echo 0)" -gt 0 ]; then
      log "Picosnitch 已采集到连接记录"
      break
    fi
    sleep 3
  done
  if [ ! -s "$PICOSNITCH_DB" ]; then
    echo "Picosnitch 数据库未生成：$PICOSNITCH_DB"
    systemctl status picosnitch.service --no-pager -l | head -20
    exit 1
  fi
  # 桌面通知相关错误只在无图形环境时出现，记录但不阻断
  if [ -s /var/log/picosnitch/error.log ]; then
    log "Picosnitch 错误日志（前 5 行）："
    head -5 /var/log/picosnitch/error.log
  fi
  echo
  echo "Picosnitch Web: http://${PICOSNITCH_WEB_HOST}:${PICOSNITCH_WEB_PORT}"
  echo "Traffic Guard Web: http://${TRAFFIC_GUARD_WEB_HOST}:${TRAFFIC_GUARD_WEB_PORT}（Basic 用户名：admin，密码见 /etc/traffic-guard/web-token）"
}

validate_inputs
install_packages
install_picosnitch
configure_picosnitch
write_picosnitch_services
write_traffic_guard_files
write_traffic_guard_services
write_mail_config
enable_services
verify
