# LinuxNet Server Stack

这套脚本会在 Ubuntu 服务器上一次性部署：

- `Picosnitch`
- `Picosnitch Web`
- `traffic-guard`
- `traffic-guard Web`
- 关机前 Gmail SMTP 通知

## 文件

- [scripts/install_linuxnet_stack.sh](scripts/install_linuxnet_stack.sh)
- [templates/traffic-guard-web.py](templates/traffic-guard-web.py)
- [templates/check-tx-shutdown.sh](templates/check-tx-shutdown.sh)
- [templates/send-shutdown-mail.sh](templates/send-shutdown-mail.sh)
- [templates/gmail-notify.conf.example](templates/gmail-notify.conf.example)

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

两个 Web 服务默认只监听 `127.0.0.1`，不要直接暴露到公网。通过 SSH 隧道访问：

```bash
ssh -L 5100:127.0.0.1:5100 -L 5101:127.0.0.1:5101 root@server
```

浏览器打开 `http://127.0.0.1:5100` 和 `http://127.0.0.1:5101`。Traffic Guard 用户名为 `admin`，密码保存在服务器的 `/etc/traffic-guard/web-token`。如需域名访问，应使用带 TLS 和访问控制的反向代理，代理到本机监听端口。

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

## 自动测试与部署

每次 push 和 pull request 都会运行 Shell 语法、ShellCheck、Python 单元测试和编译检查。部署工作流默认关闭；配置仓库变量 `ENABLE_DEPLOY=true`，并添加以下 Secrets 后，`main` 分支 CI 成功会让服务器在 `/opt/linuxnet` 拉取并重新部署：

- `DEPLOY_SERVER_HOST`
- `DEPLOY_SERVER_USER`（可选，默认 `root`）
- `DEPLOY_SSH_PRIVATE_KEY`
- `DEPLOY_KNOWN_HOSTS`（预先核验的服务器 SSH host key）

安全设计和运维注意事项见 [docs/security.md](docs/security.md)。
