# Ubuntu 大版本升级经验

## 版本路径是硬约束

Ubuntu **不支持跨版本直升**。要到 26.10，必须：

```
24.04 LTS → 26.04 LTS → 26.10
```

每次只走一步。跳版本会直接报错或进入异常状态。

## 非 LTS 目标需要两个开关

```bash
# 1. 放开开发版策略
sed -i 's/^Prompt=.*/Prompt=normal/' /etc/update-manager/release-upgrades

# 2. 加 -d 参数
do-release-upgrade -d
```

只改 `Prompt=normal` 会报 `No new release found`，只加 `-d` 而 `Prompt=lts` 会报 `There is no development version of an LTS available`。两个都要。

先验证一次再动手：

```bash
do-release-upgrade -c -d
# 期望输出 New release '26.10' available.
```

## 升级前必须先满足三个前置条件

| 报错 | 解决 |
|---|---|
| `Please install all available updates for your release before upgrading.` | `apt-get full-upgrade` |
| `You have not rebooted after updating a package which requires a reboot.` | `systemctl reboot` |
| 仍有个别包未升级 | `apt-get install systemd libsystemd0`（Phased Update 卡住的包） |

**“升级前后各重启一次”不是可选项。** 本项目两台机器共重启了 6 次。

## 无人值守升级的正确写法

用 tmux 包裹，避免 SSH 断连：

```bash
tmux new-session -d -s upgrade "sudo -n bash -c '
  export DEBIAN_FRONTEND=noninteractive
  apt-get -y -o Dpkg::Options::=--force-confold -o Dpkg::Options::=--force-confdef full-upgrade
  do-release-upgrade -d -f DistUpgradeViewNonInteractive
  echo EXIT_CODE=\$?
' 2>&1 | tee -a /var/log/upgrade.log"
```

关键点：

- `DistUpgradeViewNonInteractive` 避免交互式提问卡住
- `--force-confold` 保留现场配置文件，不会被新版覆盖
- 末尾打 `EXIT_CODE=` 便于脚本判断，比读日志猜快得多
- 日志文件先 `chown` 给普通用户，因为升级中 `sudo` 会短暂消失

## 最大的坑：Python 大版本升级会废掉 venv

24.04 是 Python 3.12，26.04/26.10 是 **3.14**。

升级后任何基于 venv 的服务都会挂掉：

```
/opt/xxx-venv/bin/python3: No module named xxx
```

原因：venv 目录仍叫 `lib/python3.12`，但 `/usr/bin/python3` 已经是 3.14，`pyvenv.cfg` 里还写着 `version = 3.12.3`。venv 的 `bin/python3` 是指向系统解释器的软链，解释器变了但包目录没变，自然找不到模块。

**正确做法：安装脚本必须能检测并重建**

```bash
venv_version=""
[ -f "$VENV/pyvenv.cfg" ] && venv_version=$(sed -n 's/^version = //p' "$VENV/pyvenv.cfg" | head -1)
system_version=$(python3 -c 'import platform; print(platform.python_version())')
if [ -n "$venv_version" ] && [ "$venv_version" != "$system_version" ]; then
  rm -rf "$VENV"
fi
python3 -m venv "$VENV"
```

**排查信号**：`systemctl is-active` 显示 `activating` 且 `NRestarts` 持续增长，日志里是 `No module named`。不要只看 `is-active` 就以为服务正常。

## 升级期间 sudo 会短暂消失

替换 `sudo` 包的过程中 `/usr/bin/sudo` 不存在，SSH 执行报 `bash: sudo: command not found`。这不是故障，等升级走完就恢复。但意味着：

- 升级期间不要依赖 `sudo` 做紧急操作
- 需要看的日志要提前 `chown` 成普通用户可读
- 监控脚本如果依赖 sudo 会误报

## 升级后必查清单

```bash
lsb_release -d                              # 版本
uname -r                                    # 内核（应是新内核，否则还没重启）
python3 -V                                  # Python 版本变化
systemctl is-active <所有业务单元>           # 每个都要 active
ss -tlnp | grep -oE ':(80|443|...) '        # 端口是否齐全
```

对 systemd 服务还要额外查：

```bash
systemctl show <unit> -p NRestarts --value  # 应为 0
journalctl -u <unit> -n 50 --no-pager       # 看有无 No module named
```

## 本项目实测数据

| | uw | ue |
|---|---|---|
| 升级前 | 24.04.5 / 7.0.0-1017 | 同 |
| 升级后 | 26.10 / 7.3.0-1004 | 同 |
| 总耗时 | 约 1.5 小时 | 约 1.5 小时 |
| 重启次数 | 3 | 3 |

保留完好：业务二进制与配置、链路聚合、系统单元、数据库、流量状态文件。
