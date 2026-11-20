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
TRAFFIC_GUARD_WARN_PERCENT=80 \
TRAFFIC_GUARD_INTERVAL_SECONDS=10 \
PICOSNITCH_WEB_PORT=5100 \
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

- `Picosnitch` 使用 2.2.1（预编译 CO-RE BPF，兼容 6.x/7.x 内核）
- `Picosnitch Web` 监听 `127.0.0.1:5100`
- `traffic-guard.timer` 默认每 `10 秒` 检查一次
- `traffic-guard Web` 默认每 `10 秒` 刷新一次
- 出站流量按**自然月**累计：跨月自动清零，跨重启继续累计（内核计数器回绕不会清零已用量）
- 达到 `80%` 发一次预警邮件；达到阈值再发一次关机邮件，然后执行 `poweroff`
- 同一事件只发一封邮件，`ACTION=none` 时也不会每 10 秒刷邮箱
- 邮件正文为 `Picosnitch` 上传前 5、下载前 5 程序

额外环境变量：

```bash
TRAFFIC_GUARD_WARN_PERCENT=80   # 预警线百分比，0 表示关闭预警
TRAFFIC_GUARD_ACTION=none       # none = 只发通知不关机，便于先观察
```

## 关键约束（踩过的坑）

- **Ubuntu 24.04 自带 Python 3.12**：`pandas` 必须用有 cp312 wheel 的版本。
- **内核 6.14+/7.x 不能用 BCC 0.29 编译 BPF**：`BPF_LOAD_ACQ`、`BPF_STORE_REL`、`BPF_F_CPU`、`BPF_TRACE_FSESSION` 等新常量缺失。因此必须用 picosnitch 2.x 的预编译 CO-RE 对象，不要退回 1.x。
- **`unattended-upgrades` 会持有 dpkg 锁**：安装脚本只在 apt 报锁冲突时重试；不能用 `pgrep unattended` 判断，因为 `unattended-upgrade-shutdown` 是常驻进程并不持锁。
- **picosnitch 2.x 数据库结构与 1.x 不同**：`exe` 规范化到 `executables` 表，查询必须 JOIN。

## 当前开发进度

v0.0.5 已完成 picosnitch 2.2.1 升级，并在 uw.sbbz.tech、ue.sbbz.tech 两台服务器实际部署验证通过。详见 [docs/20261120-1310-当前开发进度-未标注.md](docs/20261120-1310-当前开发进度-未标注.md)。

## 下一步待实现

剩余待办（Bark 推送兜底、Web 端编辑预警线、部署回滚等）见 [docs/20261120-1310-下一步待实现-未标注.md](docs/20261120-1310-下一步待实现-未标注.md)。

## 自动测试与部署

每次 push 和 pull request 都会运行 Shell 语法、ShellCheck、流量守卫判定逻辑验证、Python 单元测试和编译检查。部署工作流默认关闭；配置仓库变量 `ENABLE_DEPLOY=true`，并添加以下 Secrets 后，`main` 分支 CI 成功会让服务器在 `/opt/linuxnet` 首次 clone 或拉取并重新部署：

- `DEPLOY_SERVER_HOST`
- `DEPLOY_SERVER_USER`（可选，默认 `root`）
- `DEPLOY_SSH_PRIVATE_KEY`
- `DEPLOY_KNOWN_HOSTS`（预先核验的服务器 SSH host key）

安全设计和运维注意事项见 [docs/security.md](docs/security.md)，全部文档见 [文档索引.md](文档索引.md)。
