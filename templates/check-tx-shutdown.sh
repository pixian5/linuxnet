#!/usr/bin/env bash
set -euo pipefail

IFACE="${IFACE:-eth0}"
LIMIT_BYTES="${LIMIT_BYTES:-1073741824}"
ACTION="${ACTION:-poweroff}"
WARN_PERCENT="${WARN_PERCENT:-80}"
STATE_FILE="${STATE_FILE:-/var/lib/traffic-guard/${IFACE}.baseline}"
# 可替换内核输入和外部程序，以便隔离测试
BOOT_ID_FILE="${BOOT_ID_FILE:-/proc/sys/kernel/random/boot_id}"
TX_FILE="${TX_FILE:-/sys/class/net/${IFACE}/statistics/tx_bytes}"
MAIL_SCRIPT="${MAIL_SCRIPT:-/usr/local/lib/traffic-guard/send-shutdown-mail.sh}"
PERIOD="$(date +%Y-%m)"

is_uint() {
  [[ "$1" =~ ^[0-9]+$ ]]
}

if [ ! -r "$TX_FILE" ]; then
  logger -t traffic-guard "网卡 ${IFACE} 不存在，跳过本次检查"
  exit 1
fi

# 启动标识读不到时不能让 set -e 直接退出，否则下面的日志永远不会输出
boot_id="$(cat "$BOOT_ID_FILE" 2>/dev/null || true)"
if [ -z "$boot_id" ]; then
  logger -t traffic-guard "无法读取启动标识 ${BOOT_ID_FILE}，拒绝更新流量基线"
  exit 1
fi
current="$(cat "$TX_FILE")"
if ! is_uint "$current" || ! is_uint "$LIMIT_BYTES" || [ "$LIMIT_BYTES" -le 0 ]; then
  logger -t traffic-guard "计数器或阈值非法，跳过本次检查"
  exit 1
fi

# 状态文件记录：本周期累计出站流量、上次看到的内核计数器、周期、预警/超限通知标记
state_period=""
state_boot_id=""
total=0
last=""
warned=0
alerted=0
if [ -f "$STATE_FILE" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    [ -z "$line" ] && continue
    if [[ "$line" != *=* ]]; then
      # 旧格式：单行整数，语义等同于上次的内核计数器（累计值从 0 开始）
      is_uint "$line" && last="$line"
      continue
    fi
    key="${line%%=*}"
    value="${line#*=}"
    case "$key" in
      BOOT_ID) state_boot_id="$value" ;;
      PERIOD) state_period="$value" ;;
      TOTAL_BYTES) is_uint "$value" && total="$value" ;;
      LAST_COUNTER) is_uint "$value" && last="$value" ;;
      WARNED) is_uint "$value" && warned="$value" ;;
      ALERTED) is_uint "$value" && alerted="$value" ;;
      *) ;;
    esac
  done < "$STATE_FILE"
fi

# 旧格式（单行整数）没有周期字段，视为当前周期，保留其基线继续累计，避免升级后已用量丢失
if [ -n "$last" ] && [ -z "$state_period" ]; then
  state_period="$PERIOD"
fi

if [ "$state_period" != "$PERIOD" ]; then
  # 新的计费周期：累计清零，计数器基线对齐到当前值，通知标记复位
  total=0
  last="$current"
  warned=0
  alerted=0
  logger -t traffic-guard "进入新的计费周期 ${PERIOD}，累计出站流量已重置"
elif [ -z "$last" ]; then
  # 首次运行或状态文件损坏：从现在开始计数
  last="$current"
  warned=0
  alerted=0
elif [ -n "$state_boot_id" ] && [ "$state_boot_id" != "$boot_id" ]; then
  # 同月重启后，当前启动的全部出站字节均未计入旧累计
  last=0
  logger -t traffic-guard "检测到新的启动，计入本次启动的 ${current} bytes"
elif [ "$current" -lt "$last" ]; then
  # 同次启动或旧状态缺少启动标识：保留既有回绕策略
  last="$current"
  logger -t traffic-guard "检测到计数器回绕，保留已累计出站流量 ${total} bytes"
fi

used=$((total + current - last))
total="$used"

# 先落盘再发信/关机，保证重启后不会丢失已统计的流量
write_state() {
  local tmp
  tmp="$(mktemp "${STATE_FILE}.XXXXXX")"
  printf 'PERIOD=%s\nBOOT_ID=%s\nTOTAL_BYTES=%s\nLAST_COUNTER=%s\nWARNED=%s\nALERTED=%s\n' \
    "$PERIOD" "$boot_id" "$total" "$current" "$warned" "$alerted" > "$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$STATE_FILE"
}

should_warn=0
if is_uint "$WARN_PERCENT" && [ "$WARN_PERCENT" -gt 0 ] && [ "$WARN_PERCENT" -lt 100 ] && [ "$warned" -eq 0 ]; then
  warn_bytes=$((LIMIT_BYTES * WARN_PERCENT / 100))
  if [ "$used" -ge "$warn_bytes" ] && [ "$used" -lt "$LIMIT_BYTES" ]; then
    should_warn=1
    warned=1
  fi
fi

over_limit=0
should_alert=0
if [ "$used" -ge "$LIMIT_BYTES" ]; then
  over_limit=1
  if [ "$alerted" -eq 0 ]; then
    should_alert=1
    alerted=1
  fi
  # 已越过阈值时不再补发预警邮件：
  # 多数邮件服务商（如 189）对短时间连续发信会限流（535 authentication failed），
  # 一发预警+一发关机很容易让真正重要的关机通知被拒。
  warned=1
fi

write_state

# 对整个发信步骤（含重试）限时，强制终止后仍继续原有动作
send_mail() {
  timeout -k 5s 120s "$MAIL_SCRIPT" "$@" ||
    logger -t traffic-guard "${1} 邮件发送失败或超时（退出码 $?），继续执行既定策略" || true
}

if [ "$should_warn" -eq 1 ]; then
  logger -t traffic-guard "出站流量已达预警线 ${WARN_PERCENT}%（${used}/${LIMIT_BYTES} bytes）"
  send_mail warning "$used" "$LIMIT_BYTES" "$WARN_PERCENT"
fi

if [ "$over_limit" -eq 0 ]; then
  exit 0
fi

logger -t traffic-guard "网卡 ${IFACE} 出站流量达到阈值 ${used} bytes（阈值 ${LIMIT_BYTES}），action=${ACTION}"
# 已通知过就不再重复发信，避免 ACTION=none 时每轮刷邮箱
if [ "$should_alert" -eq 1 ]; then
  send_mail shutdown "$used" "$LIMIT_BYTES"
fi

case "$ACTION" in
  poweroff)
    "${POWEROFF_CMD:-/sbin/poweroff}"
    ;;
  halt)
    /sbin/halt
    ;;
  none)
    logger -t traffic-guard "ACTION=none：仅发送通知，不执行关机"
    ;;
  *)
    logger -t traffic-guard "未知动作 ${ACTION}，拒绝继续"
    exit 1
    ;;
esac
