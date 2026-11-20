# SMTP 邮件配置经验

## 端口与 TLS 模式必须匹配

| 端口 | TLS 模式 | msmtp 配置 |
|---|---|---|
| 465 | 隐式 TLS（连上就是 SSL） | `tls on` + `tls_starttls off` |
| 587 | 明文连接后 STARTTLS 升级 | `tls on` + `tls_starttls on` |
| 25 | 通常无 TLS | 不建议用于公网 |

**端口选错或模式选错，症状是连接挂起或握手失败，而不是明确的报错。** 本项目原实现硬编码 `tls_starttls on`，遇到 465 端口会失败。

推荐按端口自动推断：

```bash
if [ -z "$SMTP_STARTTLS" ]; then
  if [ "$SMTP_PORT" = "465" ]; then SMTP_STARTTLS="off"; else SMTP_STARTTLS="on"; fi
fi
```

## 必须配置证书信任文件

```ini
tls_trust_file /etc/ssl/certs/ca-certificates.crt
```

不配这一行，msmtp 的行为取决于版本和编译选项，新版本可能直接拒绝连接或跳过校验。后者更危险，等于没有 TLS。

## 密码里的特殊字符会炸掉配置文件

这是本项目真实踩到的坑。189 邮箱密码 `<SMTP_PASSWORD>` 包含 `#`、`(`、`!`。

写入这种配置文件时：

```bash
# 错误：密码中的 # 会被 source 当作注释
cat > conf <<EOF
SMTP_PASS=${SMTP_PASS}
EOF

# 正确：单引号包裹，内部单引号转义为 '\''
sq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
echo "SMTP_PASS=$(sq "$SMTP_PASS")" >> conf
```

报错样例（很难一眼看出是密码问题）：

```
/etc/traffic-guard/gmail-notify.conf: line 7: syntax error near unexpected token `('
```

## 中文邮箱的 SMTP 地址

| 服务商 | 地址 | 端口 |
|---|---|---|
| 189 / 21CN | `smtp.189.cn` | 465 / 587 |
| QQ 邮箱 | `smtp.qq.com` | 465 / 587 |
| 163 | `smtp.163.com` | 465 / 994 |

注意 189 邮箱需要用**授权码**还是登录密码，取决于是否开启了独立密码。本项目实测直接用登录密码可成功认证。

## 验证顺序（不要跳步）

1. **连通性**：`timeout 8 bash -c 'cat < /dev/null > /dev/tcp/smtp.189.cn/465'`
2. **认证**：用 Python `smtplib` 登录一次，确认账号密码有效
   ```python
   server = smtplib.SMTP_SSL("smtp.189.cn", 465, context=ssl.create_default_context())
   server.login(user, password)   # 应返回 235
   ```
3. **msmtp 发信**：手工构造最小配置发一封
4. **完整链路**：跑真实的 `check-tx-shutdown.sh`，确认触发条件、状态标记、实际发信都对

跳过第 2 步直接用 msmtp 排查，会把认证失败和配置语法错误混在一起。

## 邮件商会限流，不要短时间连发

189 邮箱实测：连续发信会返回

```
msmtp: server message: 535 authentication failed: -200
smtpmsg='535 authentication failed: -200' errormsg='authentication failed (method LOGIN)'
```

**这个报错看起来像密码错了，其实是限流。** 间隔 20 秒后同样的配置就能成功。

排查时要先确认“同样的配置之前成功过吗”。如果成功过，优先怀疑限流而不是密码。

### 处理方式：失败后延迟重试

限流是暂时的，等一会儿就好。关机通知丢失的代价远大于多等 30 秒，因此应当重试而不是放弃：

```bash
attempt=1
while :; do
  if send_mail; then exit 0; fi
  if [ "$attempt" -ge "$MAIL_MAX_ATTEMPTS" ]; then
    logger -t traffic-guard "邮件发送失败，已尝试 ${attempt} 次"
    exit 1
  fi
  sleep "$MAIL_RETRY_DELAY"
  attempt=$((attempt + 1))
done
```

默认 `MAIL_RETRY_DELAY=30`、`MAIL_MAX_ATTEMPTS=3`。

### 关键陷阱：systemd 超时会杀掉重试

如果这个发信脚本由 `Type=oneshot` 的 systemd 服务调用，**默认 `TimeoutStartSec=90s` 会在重试期间杀掉脚本**，导致后面的 `poweroff` 永远不执行——守卫彻底失效，比邮件发不出去严重得多。

3 次尝试 × (连接超时 + 30 秒) 很容易超过 90 秒。必须显式放宽：

```ini
[Service]
Type=oneshot
TimeoutStartSec=300
```

这个坑静态检查查不出来，只有在真机上跑一次失败重试才能发现。

### 不要去重到“只发一封”

有人会想“既然会限流，那预警和关机就合并成一封”。但两者语义不同：预警是提醒你还有缓冲，关机是通知服务已中断。本项目选择的是——越过阈值时不再补发预警，只发关机通知；预警只在未越线时发。这样既避免连发，又不丢关键信息。

## 日志位置

本项目 msmtp 日志写到 `/var/log/traffic-guard-msmtp.log`。成功的样子：

```
host=smtp.189.cn tls=on auth=on user=... recipients=...
smtpstatus=250 smtpmsg='250 OK' exitcode=EX_OK
```

只看命令退出码不够，因为 `send-shutdown-mail.sh` 里用了 `|| true`，发信失败不会中断关机流程。必须查日志确认 `exitcode=EX_OK`。
