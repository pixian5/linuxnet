# LinuxNet 安全与运维说明

## Web 服务边界

Picosnitch Dash 和 Traffic Guard Web 默认只监听回环地址。公网访问应通过 SSH 隧道，或由提供 TLS、认证和限流的反向代理转发，禁止直接把 `5100`、`5101` 端口开放到公网。

Traffic Guard Web 即使只监听本机，也强制使用 Basic Auth。用户名固定为 `admin`，随机密码保存在 `/etc/traffic-guard/web-token`，权限为 `0600`。修改阈值的请求还必须携带基于该密码生成的 CSRF 令牌。

该 Web 服务具有修改 `/etc/default/traffic-guard` 和启动检查服务的权限。检查服务可能执行关机，因此认证文件、反向代理配置和 SSH 访问权限都应按 root 级敏感度管理。

## 防护措施

- 请求体上限为 16 KiB。
- 每个连接读取超时为 5 秒。
- 同时处理的请求线程最多 32 个。
- 配置通过同目录临时文件和原子替换写入，并保留管理员手工添加的其它键。
- 阈值限制在 Bash 64 位有符号整数可表达的范围内。
- Web 修改后会检查 `systemctl start traffic-guard.service` 的退出状态，不再把失败显示为成功。

## 流量状态文件

`/var/lib/traffic-guard/<网卡>.baseline` 记录本周期累计出站流量与上次看到的内核计数器，权限 `0600`，由检查脚本原子写入。它决定何时关机，属于安全敏感文件：

- 删除它会清空本周期累计（从当前计数器重新起算），等同于手动重置配额。
- 篡改它可让守卫永不触发。该目录只应对 root 可写。
- 状态文件同时记录 `WARNED`/`ALERTED`，用于保证同一事件只发一封邮件。

## 安装与验证

安装脚本固定 Picosnitch 和 Dashboard 依赖版本，并验证第三方源码补丁的命中次数。上游源码结构变化时安装会明确失败，避免静默得到错误 UI。每次部署会先用 `--force-reinstall` 还原上游文件再打补丁，因此安装脚本可以重复执行。

安装结束必须满足以下条件：

- 四个 systemd 单元均为 active。
- Picosnitch Dash 返回 HTTP 200。
- Traffic Guard Web 经认证后返回 HTTP 200。

若验证失败，先查看：

```bash
journalctl -u picosnitch.service -u picosnitch-dash.service -u traffic-guard.timer -u traffic-guard-web.service --no-pager -n 200
```

## GitHub Actions 部署

部署工作流只有在仓库变量 `ENABLE_DEPLOY` 为 `true`、CI 成功且目标分支为 `main` 时运行。服务器目录固定为 `/opt/linuxnet`；目录不存在时首次 clone，已有仓库使用 `git pull --ff-only`，非 Git 目录则明确失败，避免误覆盖服务器文件。安装脚本会重启受影响的 systemd 单元，确保新版本实际生效。服务器 host key 必须预先核验并保存到 `DEPLOY_KNOWN_HOSTS` Secret，工作流不会在部署时临时信任 `ssh-keyscan` 的结果。
