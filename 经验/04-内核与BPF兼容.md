# 内核与 BPF 兼容性经验（重要）

## 一句话

**在 6.14+/7.x 内核上，任何“运行时用系统 BCC 编译 BPF 源码”的工具都可能整体失效。** Ubuntu 24.04 的 BCC 停留在 0.29.1，其兼容头不认新内核常量。

## 具体表现

picosnitch 1.0.3 在内核 7.0.0-azure 上：

```
include/linux/bpf.h:1085: error: use of undeclared identifier 'BPF_LOAD_ACQ'
include/linux/bpf.h:1086: error: use of undeclared identifier 'BPF_STORE_REL'
include/linux/bpf.h:3997: error: use of undeclared identifier 'BPF_F_CPU'
include/linux/bpf.h:4000: error: use of undeclared identifier 'BPF_F_ALL_CPUS'
include/linux/bpf.h:2197: error: use of undeclared identifier 'BPF_TRACE_FSESSION'
```

服务表现为 `activating` + 无限重启，`NRestarts` 持续增长。

## 为什么补宏不管用

这些常量确实定义在内核 uapi 头里（如 `uapi/linux/bpf.h` 的匿名 enum），但 `linux/bpf.h` 内部引用时未引入对应 enum，BCC 的 C 编译环境看不到。缺的常量有好几个且会随内核继续增加，逐个补宏不可维护。实测只补 `BPF_F_CPU` / `BPF_F_ALL_CPUS` 后，仍然报 `BPF_LOAD_ACQ`、`BPF_STORE_REL`、`BPF_TRACE_FSESSION`。

## 正确解法（按优先级）

1. **换用预编译 CO-RE 对象**：程序自带 `.bpf.o`，运行时不编译。这是 picosnitch 2.x 的做法，也是最省事的。
2. 从源码编译新版 BCC（0.37+ 明确支持内核到 7.1），但耗时长、后续内核升级仍有风险。
3. 用 `bpftrace` 重写采集逻辑（Ubuntu 24.04 自带，且不依赖 BCC 的 C 头）。

## 排查手法

```bash
# 1. 看是否无限重启
systemctl show picosnitch.service -p NRestarts --value

# 2. 看真实错误（不要只看 is-active）
journalctl -u picosnitch.service -n 100 --no-pager | grep -i "error\|exception"

# 3. 最小复现：BCC 能否编译最简单的程序
python3 -c 'from bcc import BPF; BPF(text="int kprobe__do_sys_open(void *ctx){return 0;}")'
# 能过说明 BCC 本身可用，问题在具体程序的 BPF 源码
```

## 教训

- **`is-active` 不能证明服务在工作**。picosnitch 卡在 `activating` 时，`systemctl is-active` 会返回非 0 但很容易被忽略；必须同时查 `NRestarts` 和日志。
- **验证要查“有没有产出数据”**。安装脚本现在会在部署后等待数据库出现连接记录，而不是只看 unit 状态。
- 云厂商的内核往往比 Ubuntu 官方新很多（Azure 已到 7.0），本地容器测试（Ubuntu 24.04 默认内核）**测不出这类问题**。
