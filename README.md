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
- [templates/mail-notify.conf.example](templates/mail-notify.conf.example)

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

启用邮件通知（支持任意 SMTP，下面以 189 邮箱 465 端口为例）：

```bash
ENABLE_MAIL_NOTIFY=1 \
MAIL_FROM=your@189.cn \
MAIL_TO=your@189.cn \
SMTP_HOST=smtp.189.cn \
SMTP_PORT=465 \
SMTP_STARTTLS=off \
SMTP_USER=your@189.cn \
SMTP_PASS=your_smtp_password \
bash scripts/install_linuxnet_stack.sh
```

`SMTP_STARTTLS` 留空时按端口自动判断：`465` → `off`（隐式 TLS），其它端口 → `on`（STARTTLS）。Gmail 用 `smtp.gmail.com:587` + 应用专用密码。

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

- **安装脚本重跑不能覆盖现场配置**：阈值、动作、邮件参数都从服务器已有配置继承，显式环境变量优先。CI 部署不带任何变量，靠这条规则才不会把 50 GB 阈值重置回 1 GB。
- **Ubuntu 24.04 自带 Python 3.12**：`pandas` 必须用有 cp312 wheel 的版本。
- **内核 6.14+/7.x 不能用 BCC 0.29 编译 BPF**：`BPF_LOAD_ACQ`、`BPF_STORE_REL`、`BPF_F_CPU`、`BPF_TRACE_FSESSION` 等新常量缺失。因此必须用 picosnitch 2.x 的预编译 CO-RE 对象，不要退回 1.x。
- **`unattended-upgrades` 会持有 dpkg 锁**：安装脚本只在 apt 报锁冲突时重试；不能用 `pgrep unattended` 判断，因为 `unattended-upgrade-shutdown` 是常驻进程并不持锁。
- **picosnitch 2.x 数据库结构与 1.x 不同**：`exe` 规范化到 `executables` 表，查询必须 JOIN。
- **189 邮箱短时间连发会被限流**：返回 `535 authentication failed`，看起来像密码错误。发信失败会延迟 30 秒重试（最多 3 次）；`traffic-guard.service` 的 `TimeoutStartSec` 已放宽到 300 秒，否则重试期间 systemd 会杀掉脚本、`poweroff` 永不执行。
- **Ubuntu 大版本升级会让 venv 失效**：24.04 的 Python 3.12 → 26.04/26.10 的 3.14，旧 venv 报 `No module named picosnitch` 并无限重启。安装脚本已能检测 `pyvenv.cfg` 版本差异并自动重建。

## 当前开发进度

v0.0.13 已完成两台服务器从 Ubuntu 24.04 到 26.10 的升级（内核 7.3.0-1004-azure），并修复 Python 3.14 导致的 venv 失效。详见 [docs/20261120-1759-当前开发进度-未标注.md](docs/20261120-1759-当前开发进度-未标注.md)。

## 下一步待实现

剩余待办（关机流程真机验证、50GB 计量口径核对、Bark 兜底等）见 [docs/20261120-1622-下一步待实现-未标注.md](docs/20261120-1622-下一步待实现-未标注.md)。

## 自动测试与部署

每次 push 和 pull request 都会运行 Shell 语法、ShellCheck、流量守卫判定逻辑验证、邮件重试验证、Python 单元测试和编译检查。部署工作流默认关闭；配置仓库变量 `ENABLE_DEPLOY=true`，并添加以下 Secrets 后，`main` 分支 CI 成功会让服务器在 `/opt/linuxnet` 首次 clone 或拉取并重新部署：

- `DEPLOY_SERVER_HOST`
- `DEPLOY_SERVER_USER`（可选，默认 `root`）
- `DEPLOY_SSH_PRIVATE_KEY`
- `DEPLOY_KNOWN_HOSTS`（预先核验的服务器 SSH host key）

安全设计和运维注意事项见 [docs/security.md](docs/security.md)，全部文档见 [文档索引.md](文档索引.md)。
