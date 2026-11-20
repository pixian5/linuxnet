#!/usr/bin/env bash
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "请用 root 运行此脚本"
  exit 1
fi

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$(cd "${SCRIPT_DIR}/.." && pwd)
TEMPLATE_DIR="${ROOT_DIR}/templates"

# 读取服务器上已有的 /etc/default/traffic-guard 配置。
# 目的：CI 部署时不带任何环境变量，如果直接用代码里的默认值覆盖，
# 会把管理员通过 Web 面板或手工改过的阈值/动作重置回默认值，可能造成误关机。
read_existing() {
  local key="$1" file="/etc/default/traffic-guard"
  if [ -f "$file" ]; then
    sed -n "s/^${key}=//p" "$file" | tail -1
  fi
}

EXISTING_LIMIT_BYTES="$(read_existing LIMIT_BYTES)"
EXISTING_IFACE="$(read_existing IFACE)"
EXISTING_ACTION="$(read_existing ACTION)"
EXISTING_WARN="$(read_existing WARN_PERCENT)"

if [[ "$EXISTING_LIMIT_BYTES" =~ ^[0-9]+$ ]] && [ "$EXISTING_LIMIT_BYTES" -ge 1048576 ]; then
  EXISTING_LIMIT_MIB=$((EXISTING_LIMIT_BYTES / 1024 / 1024))
else
  EXISTING_LIMIT_MIB=1024
fi

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
# 这三项的默认值优先取服务器上已有配置（见上方 read_existing），
# 其次才是代码里的兜底值。这样 CI 重部署不会覆盖现场调好的阈值。
TRAFFIC_GUARD_IFACE="${TRAFFIC_GUARD_IFACE:-${EXISTING_IFACE:-eth0}}"
TRAFFIC_GUARD_LIMIT_MIB="${TRAFFIC_GUARD_LIMIT_MIB:-$EXISTING_LIMIT_MIB}"
TRAFFIC_GUARD_ACTION="${TRAFFIC_GUARD_ACTION:-${EXISTING_ACTION:-poweroff}}"
TRAFFIC_GUARD_WARN_PERCENT="${TRAFFIC_GUARD_WARN_PERCENT:-${EXISTING_WARN:-80}}"
TRAFFIC_GUARD_INTERVAL_SECONDS="${TRAFFIC_GUARD_INTERVAL_SECONDS:-10}"
# 邮件通知开关。旧名 ENABLE_GMAIL_NOTIFY 保留兼容，新名更通用（支持 189/QQ/Gmail 等任意 SMTP）
# 注意：这里先记下“用户是否显式设置过”，不能直接赋默认值，
# 否则无法区分“用户没说”和“用户明确关闭”，会导致下面读取已有配置时判断失败。
MAIL_NOTIFY_EXPLICIT="${ENABLE_MAIL_NOTIFY:-${ENABLE_GMAIL_NOTIFY:-}}"
ENABLE_MAIL_NOTIFY="${MAIL_NOTIFY_EXPLICIT:-0}"

MAIL_FROM="${MAIL_FROM:-}"
MAIL_TO="${MAIL_TO:-}"
# SMTP_HOST / SMTP_PORT / SMTP_STARTTLS 不能在这里赋默认值，
# 否则下面的“读取已有配置”会永远拿不到空值分支。
SMTP_HOST="${SMTP_HOST:-}"
SMTP_PORT="${SMTP_PORT:-}"
SMTP_STARTTLS="${SMTP_STARTTLS:-}"
SMTP_USER="${SMTP_USER:-}"
SMTP_PASS="${SMTP_PASS:-}"

# 若服务器上已有邮件配置，则在未显式传入时自动继承并视为“已启用”。
# 否则 CI 重部署（不带任何环境变量）会跳过邮件配置写入，
# 虽不会删掉旧文件，但一旦上游模板或路径变化就会静默失去通知能力。
MAIL_CONF_FILE="/etc/traffic-guard/gmail-notify.conf"
if [ -f "$MAIL_CONF_FILE" ]; then
  mail_existing() {
    # 配置文件里的值用单引号包裹，这里去掉首尾引号
    sed -n "s/^$1=//p" "$MAIL_CONF_FILE" | tail -1 | sed "s/^'//; s/'$//"
  }
  MAIL_FROM="${MAIL_FROM:-$(mail_existing MAIL_FROM)}"
  MAIL_TO="${MAIL_TO:-$(mail_existing MAIL_TO)}"
  SMTP_HOST="${SMTP_HOST:-$(mail_existing SMTP_HOST)}"
  SMTP_PORT="${SMTP_PORT:-$(mail_existing SMTP_PORT)}"
  SMTP_STARTTLS="${SMTP_STARTTLS:-$(mail_existing SMTP_STARTTLS)}"
  SMTP_USER="${SMTP_USER:-$(mail_existing SMTP_USER)}"
  SMTP_PASS="${SMTP_PASS:-$(mail_existing SMTP_PASS)}"
  # 已有配置且必填项齐全时，若用户没显式设置开关，则默认保持启用
  if [ -n "$MAIL_FROM" ] && [ -n "$MAIL_TO" ] && [ -n "$SMTP_USER" ] && [ -n "$SMTP_PASS" ] && [ -z "$MAIL_NOTIFY_EXPLICIT" ]; then
    ENABLE_MAIL_NOTIFY="1"
  fi
fi

# 继承完已有配置后再补默认值，保证“服务器上的值”优先于“代码默认值”
SMTP_HOST="${SMTP_HOST:-smtp.gmail.com}"
SMTP_PORT="${SMTP_PORT:-587}"

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
  # 系统 Python 大版本升级（如 24.04 的 3.12 -> 26.04 的 3.14）会让旧 venv 失效：
  # 目录还叫 lib/python3.12，解释器却已是 3.14，启动时报 No module named picosnitch。
  # 这里检测 pyvenv.cfg 记录的版本与当前 python3 是否一致，不一致就重建。
  local venv_version=""
  if [ -f "${PICOSNITCH_VENV}/pyvenv.cfg" ]; then
    venv_version=$(sed -n 's/^version = //p' "${PICOSNITCH_VENV}/pyvenv.cfg" | head -1)
  fi
  local system_version
  system_version=$(python3 -c 'import platform; print(platform.python_version())')
  if [ -n "$venv_version" ] && [ "$venv_version" != "$system_version" ]; then
    log "检测到 Python 版本变化（venv ${venv_version} -> 系统 ${system_version}），重建 venv"
    rm -rf "$PICOSNITCH_VENV"
  fi
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
# 邮件发送失败会延迟重试（默认 30 秒 x 最多 3 次），
# 默认 90 秒的 TimeoutStartSec 会在重试期间杀掉脚本，导致 poweroff 永远不执行。
# 这里放大到 5 分钟，保证先发信再关机的流程一定能走完。
TimeoutStartSec=300
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
  if [ "$ENABLE_MAIL_NOTIFY" != "1" ]; then
    log "跳过邮件通知配置"
    return
  fi

  if [ -z "$MAIL_FROM" ] || [ -z "$MAIL_TO" ] || [ -z "$SMTP_USER" ] || [ -z "$SMTP_PASS" ]; then
    echo "启用邮件通知时，必须提供 MAIL_FROM/MAIL_TO/SMTP_USER/SMTP_PASS"
    exit 1
  fi
  if [ -z "$SMTP_STARTTLS" ]; then
    if [ "$SMTP_PORT" = "465" ]; then
      SMTP_STARTTLS="off"
    else
      SMTP_STARTTLS="on"
    fi
  fi
  case "$SMTP_STARTTLS" in on|off) ;; *) echo "SMTP_STARTTLS 只能是 on 或 off"; exit 1 ;; esac

  log "写入邮件通知配置（${SMTP_HOST}:${SMTP_PORT}, STARTTLS=${SMTP_STARTTLS}）"
  # 密码可能含 # ( ) ! 等 shell 特殊字符，必须用单引号包裹；
  # 内容里若本身带单引号，按 shell 规则转义成 '\''
  sq() {
    printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
  }
  cat > /etc/traffic-guard/gmail-notify.conf <<EOF
MAIL_FROM=$(sq "$MAIL_FROM")
MAIL_TO=$(sq "$MAIL_TO")
SMTP_HOST=$(sq "$SMTP_HOST")
SMTP_PORT=$(sq "$SMTP_PORT")
SMTP_STARTTLS=$(sq "$SMTP_STARTTLS")
SMTP_USER=$(sq "$SMTP_USER")
SMTP_PASS=$(sq "$SMTP_PASS")
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
