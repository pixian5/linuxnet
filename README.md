# LinuxNet Server Stack

这套脚本会在 Ubuntu 服务器上一次性部署：

- `Picosnitch`
- `Picosnitch Web`
- `traffic-guard`
- `traffic-guard Web`
- 关机前 Gmail SMTP 通知

## 文件

- [scripts/install_linuxnet_stack.sh](/Users/x/code/linuxnet/scripts/install_linuxnet_stack.sh)
- [templates/traffic-guard-web.py](/Users/x/code/linuxnet/templates/traffic-guard-web.py)
- [templates/check-tx-shutdown.sh](/Users/x/code/linuxnet/templates/check-tx-shutdown.sh)
- [templates/send-shutdown-mail.sh](/Users/x/code/linuxnet/templates/send-shutdown-mail.sh)
- [templates/gmail-notify.conf.example](/Users/x/code/linuxnet/templates/gmail-notify.conf.example)

## 用法

把整个目录传到目标 Ubuntu 服务器后，以 `root` 执行：

```bash
cd /path/to/linuxnet
bash scripts/install_linuxnet_stack.sh
```

常用环境变量：

```bash
TRAFFIC_GUARD_IFACE=eth0 \
TRAFFIC_GUARD_LIMIT_MIB=1024 \
TRAFFIC_GUARD_INTERVAL_SECONDS=10 \
PICOSNITCH_DASH_PORT=5100 \
TRAFFIC_GUARD_WEB_PORT=5101 \
bash scripts/install_linuxnet_stack.sh
```

启用 Gmail 关机通知：

```bash
ENABLE_GMAIL_NOTIFY=1 \
MAIL_FROM=sender@gmail.com \
MAIL_TO=receiver@gmail.com \
SMTP_USER=sender@gmail.com \
SMTP_PASS=your_gmail_app_password \
bash scripts/install_linuxnet_stack.sh
```

## 当前默认行为

- `Picosnitch Web` 默认 `30 秒` 自动刷新
- `traffic-guard.timer` 默认每 `10 秒` 检查一次
- `traffic-guard Web` 默认每 `10 秒` 刷新一次
- 超过阈值后先发邮件，再执行 `poweroff`
- 邮件正文为 `Picosnitch` 上传前 5、下载前 5 程序
