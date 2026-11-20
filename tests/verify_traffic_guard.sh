#!/usr/bin/env bash
# 本地验证 check-tx-shutdown.sh 的累计/重启/预警/超限分支（用假计数器，不关机）
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO/templates/check-tx-shutdown.sh"
WORK="$(mktemp -d)"
FAKE_TX="$WORK/tx_bytes"
STATE="$WORK/baseline"
MAIL_LOG="$WORK/mail.log"
FAKE_MAIL="$WORK/fake-mail.sh"

cat > "$FAKE_MAIL" <<'EOF'
#!/usr/bin/env bash
echo "MAIL $*" >> "$MAIL_LOG"
EOF
chmod +x "$FAKE_MAIL"
export MAIL_LOG

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

mail_count() {
  if [ -f "$MAIL_LOG" ]; then
    grep -c "^MAIL $1" "$MAIL_LOG" || true
  else
    echo 0
  fi
}

run() {
  TX_FILE="$FAKE_TX" STATE_FILE="$STATE" MAIL_SCRIPT="$FAKE_MAIL" \
    IFACE="faketest0" bash "$SCRIPT" >/dev/null 2>&1
  return $?
}

get() {
  sed -n "s/^$1=//p" "$STATE"
}

LIMIT=104857600  # 100 MiB
PERIOD="$(date +%Y-%m)"

echo "场景 1：首次运行，从当前计数器起算"

echo 5000000 > "$FAKE_TX"
LIMIT_BYTES=$LIMIT ACTION=none WARN_PERCENT=80 run
check "首次运行成功退出" 0 $?
check "累计为 0" 0 "$(get TOTAL_BYTES)"
check "周期正确" "$PERIOD" "$(get PERIOD)"
check "未发预警" 0 "$(get WARNED)"

echo "场景 2：正常增长，累计到 10 MiB"
echo $((5000000 + 10485760)) > "$FAKE_TX"
LIMIT_BYTES=$LIMIT ACTION=none WARN_PERCENT=80 run
check "累计 10MiB" 10485760 "$(get TOTAL_BYTES)"
check "不发邮件" 0 "$(mail_count warning)"

echo "场景 3：模拟重启导致计数器回绕（当前值变小）"
echo 3000000 > "$FAKE_TX"
LIMIT_BYTES=$LIMIT ACTION=none WARN_PERCENT=80 run
check "累计值保留" 10485760 "$(get TOTAL_BYTES)"
check "计数器基线已对齐" 3000000 "$(get LAST_COUNTER)"

echo "场景 4：重启后再增长 5 MiB，累计应为 15 MiB"
echo $((3000000 + 5242880)) > "$FAKE_TX"
LIMIT_BYTES=$LIMIT ACTION=none WARN_PERCENT=80 run
check "累计 15MiB" $((10485760 + 5242880)) "$(get TOTAL_BYTES)"

echo "场景 5：达到 80% 预警线（80 MiB），只发一次预警"
echo $((3000000 + 80 * 1048576)) > "$FAKE_TX"
LIMIT_BYTES=$LIMIT ACTION=none WARN_PERCENT=80 run
check "标记已预警" 1 "$(get WARNED)"
check "发出 1 封预警邮件" 1 "$(mail_count warning)"
echo $((3000000 + 85 * 1048576)) > "$FAKE_TX"
LIMIT_BYTES=$LIMIT ACTION=none WARN_PERCENT=80 run
check "预警不重复发送" 1 "$(mail_count warning)"

echo "场景 6：达到阈值，ACTION=none 只发一次信，不关机"
BEFORE_WARN=$(mail_count warning)
echo $((3000000 + 101 * 1048576)) > "$FAKE_TX"
LIMIT_BYTES=$LIMIT ACTION=none WARN_PERCENT=80 run
check "超限后仍正常退出" 0 $?
check "发出 1 封关机信" 1 "$(mail_count shutdown)"
# 越过阈值时不能再补发预警：邮件商（如 189）会限流，导致关机信被拒
check "超限时不新增预警信" "$BEFORE_WARN" "$(mail_count warning)"
check "预警标记已置位" 1 "$(get WARNED)"
echo $((3000000 + 110 * 1048576)) > "$FAKE_TX"
LIMIT_BYTES=$LIMIT ACTION=none WARN_PERCENT=80 run
check "超限信不重复发送" 1 "$(mail_count shutdown)"
check "仍不新增预警信" "$BEFORE_WARN" "$(mail_count warning)"

echo "场景 7：跨月自动重置累计"
printf 'PERIOD=2020-01\nTOTAL_BYTES=90000000\nLAST_COUNTER=100\nWARNED=1\nALERTED=1\n' > "$STATE"
echo 7000000 > "$FAKE_TX"
LIMIT_BYTES=$LIMIT ACTION=none WARN_PERCENT=80 run
check "累计已清零" 0 "$(get TOTAL_BYTES)"
check "周期已更新" "$PERIOD" "$(get PERIOD)"
check "预警标记复位" 0 "$(get WARNED)"
check "超限标记复位" 0 "$(get ALERTED)"

echo "场景 8：旧格式状态文件（单行整数）可读"
printf '4000000\n' > "$STATE"
echo 6000000 > "$FAKE_TX"
LIMIT_BYTES=$LIMIT ACTION=none WARN_PERCENT=80 run
check "从旧基线起算 2MB" 2000000 "$(get TOTAL_BYTES)"

echo "场景 9：阈值与计数器非法时退出码为 1"
LIMIT_BYTES=0 ACTION=none run
check "零阈值被拒绝" 1 $?

echo
echo "结果：$pass 通过，$fail 失败"
rm -rf "$WORK"
[ "$fail" -eq 0 ]
