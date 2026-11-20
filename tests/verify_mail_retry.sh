#!/usr/bin/env bash
# 验证 send-shutdown-mail.sh 的失败重试逻辑（用假 msmtp，不真正发信）
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO/templates/send-shutdown-mail.sh"
WORK="$(mktemp -d)"
CONF="$WORK/mail.conf"
BIN="$WORK/bin"
MSMTP_LOG="$WORK/msmtp-calls.log"

mkdir -p "$BIN"

# 假的 msmtp：前 N 次失败，之后成功。用文件记录调用次数。
cat > "$BIN/msmtp" <<'EOF'
#!/usr/bin/env bash
count_file="${FAKE_MSMTP_COUNT:?}"
n=$(cat "$count_file" 2>/dev/null || echo 0)
n=$((n + 1))
echo "$n" > "$count_file"
echo "CALL $n" >> "${FAKE_MSMTP_LOG:?}"
fail_until="${FAKE_MSMTP_FAIL_UNTIL:-0}"
if [ "$n" -le "$fail_until" ]; then
  echo "msmtp: server message: 535 authentication failed: -200" >&2
  exit 1
fi
cat > /dev/null
exit 0
EOF
chmod +x "$BIN/msmtp"

cat > "$CONF" <<'EOF'
MAIL_FROM='test@example.com'
MAIL_TO='test@example.com'
SMTP_HOST='smtp.example.com'
SMTP_PORT='465'
SMTP_STARTTLS='off'
SMTP_USER='test@example.com'
SMTP_PASS='x'
EOF

# 脚本里写死了 /etc/traffic-guard/gmail-notify.conf，这里用临时 HOME 无法改变，
# 因此直接复制脚本并替换 CONF 路径，保持其余逻辑完全一致。
PATCHED="$WORK/mail.sh"
sed "s|^CONF=\"/etc/traffic-guard/gmail-notify.conf\"|CONF=\"$CONF\"|" "$SCRIPT" > "$PATCHED"
chmod +x "$PATCHED"

pass=0
fail=0
check() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "  PASS  ${desc}"
    pass=$((pass + 1))
  else
    echo "  FAIL  ${desc} (expected ${expected}, got ${actual})"
    fail=$((fail + 1))
  fi
}

run_mail() {
  # 参数：失败次数上限、额外环境变量...
  local fail_until="$1"; shift
  local count_file="$WORK/count.$RANDOM"
  : > "$count_file"
  : > "$MSMTP_LOG"
  # 用 env 传入额外变量，避免 "KEY=VALUE 未定义变量" 被当成命令
  PATH="$BIN:$PATH" \
    FAKE_MSMTP_COUNT="$count_file" \
    FAKE_MSMTP_LOG="$MSMTP_LOG" \
    FAKE_MSMTP_FAIL_UNTIL="$fail_until" \
    MAIL_RETRY_DELAY=0 \
    env "$@" bash "$PATCHED" warning 100 200 80 >/dev/null 2>&1
  local rc=$?
  CALLS=$(wc -l < "$MSMTP_LOG" | tr -d ' ')
  return $rc
}

echo "场景 1：首次即成功，只调用 1 次"
run_mail 0
check "退出码为 0" 0 $?
check "msmtp 调用 1 次" 1 "$CALLS"

echo "场景 2：前 2 次失败，第 3 次成功"
run_mail 2
check "退出码为 0" 0 $?
check "msmtp 调用 3 次" 3 "$CALLS"

echo "场景 3：一直失败，达到上限后放弃"
run_mail 99 MAIL_MAX_ATTEMPTS=3
check "退出码为 1" 1 $?
check "msmtp 调用 3 次后停止" 3 "$CALLS"

echo "场景 4：可自定义最大尝试次数"
run_mail 99 MAIL_MAX_ATTEMPTS=5
check "退出码为 1" 1 $?
check "msmtp 调用 5 次" 5 "$CALLS"

echo "场景 5：非法重试参数回落到默认值"
run_mail 0 MAIL_MAX_ATTEMPTS=abc MAIL_RETRY_DELAY=xyz
check "退出码为 0" 0 $?
check "仍能正常发送" 1 "$CALLS"

echo
echo "结果：$pass 通过，$fail 失败"
rm -rf "$WORK"
[ "$fail" -eq 0 ]
