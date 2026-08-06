# perf_stat_standalone

独立 oncpu time 采集脚本，不依赖 v17 实验代码，用 `perf stat task-clock` + `/proc/<tid>/stat` 两种方法测量 target vCPU 的 oncpu time，与 v17 的 `sched:sched_switch` 切片累加做交叉验证。支持 CFS / SCHED_FIFO、超分、cluster noise 全场景。

## 设计动机

v17 用 `perf kvm stat record` 采集 `sched:sched_switch` tracepoint，再由 AWK 累加切片算出 `oncpu_s`。有人质疑这种间接累加可能丢失时间（长运行无事件、边界丢失）。

本脚本用**完全独立的采集机制**验证：
- `perf stat -e task-clock`：perf 软件事件，hrtimer 采样
- `/proc/<tid>/stat`：内核调度器维护的 utime+stime 计数器

两种方法不依赖 sched_switch 事件流。若三种方法结果一致（误差 < 5%），证明 sched_switch 累加可信。

## 与 v17 的关键区别

| 维度 | v17 | standalone |
|---|---|---|
| perf 采集 | `perf kvm stat record`（sched_switch + kvm tracepoints）| `perf stat -e task-clock`（软件事件）|
| 分析方式 | AWK 分析 perf.data，累加 sched_switch 切片 | 直接读 perf stat 输出 + /proc/pid/stat |
| 窗口控制 | perf control FIFO（enable/disable ack）| perf stat 启停由 GO/DONE marker 驱动 |
| 代码依赖 | — | 完全自包含，不引用 v17 任何代码 |
| cluster noise | 支持（7 台 noise VM）| 支持（7 台 noise VM）|
| 代码量 | 2778 行 | 494 行 |

## 文件

| 文件 | 说明 |
|---|---|
| `run_perf_stat_standalone.sh` | 单次实验，启动 VM + perf stat 采集 (494 行) |
| `run_perf_stat_batch_standalone.sh` | batch: 5 workload × (CFS+FIFO) × (baseline+noise) = 20 轮 |

## 实验组合矩阵

4 个维度，单次脚本支持全组合：

| 维度 | 选项 | 数量 |
|---|---|---|
| workload | 5 个 Python 包 | 5 |
| mode | n1(单VM) / n5(target+3background超分) | 2 |
| SCHED_FIFO | CFS / FIFO | 2 |
| cluster noise | 无 / 有 | 2 |
| **全组合** | | **5×2×2×2 = 40** |

batch 默认跑 `MODE=n5` 下的 5×2×2 = **20 轮**。

### 每种组合的实验意义

| 组合 | 场景 | 测什么 |
|---|---|---|
| n1+CFS | 单 VM 独占，CFS | 纯 baseline：无干扰时的 oncpu 理论值 |
| n1+FIFO | 单 VM 独占，FIFO | FIFO 开销：独占时 FIFO vs CFS 差异 = chrt 本身开销 |
| n5+CFS | 4 VM 超分，CFS | 超分延迟：target 被抢占，oncpu_pct ~25% |
| n5+FIFO | 4 VM 超分，FIFO | FIFO 隔离：target 抢占背景，oncpu_pct ~90% |
| +noise | 邻近核 L3 干扰 | cluster noise 对 oncpu 的影响 |

## 用法

### 单次实验

```bash
cd perf_stat_standalone

# n5 + CFS (超分 baseline)
sudo ./run_perf_stat_standalone.sh joke2k__faker-2007 n5

# n5 + FIFO (超分 + SCHED_FIFO/50)
sudo SCHED_FIFO=1 ./run_perf_stat_standalone.sh joke2k__faker-2007 n5

# n5 + CFS + cluster noise (超分 + L3 干扰)
sudo CLUSTER_NOISE_CPUS=96,98,100,104,106,108,110 \
     ./run_perf_stat_standalone.sh joke2k__faker-2007 n5

# n5 + FIFO + cluster noise (全场景)
sudo CLUSTER_NOISE_CPUS=96,98,100,104,106,108,110 \
     SCHED_FIFO=1 ./run_perf_stat_standalone.sh joke2k__faker-2007 n5

# n1 + CFS (单 VM 独占)
sudo ./run_perf_stat_standalone.sh joke2k__faker-2007 n1
```

### batch 跑全组合

```bash
cd perf_stat_standalone

# 全 20 轮 (5 wl × CFS+FIFO × baseline+noise)
sudo ./run_perf_stat_batch_standalone.sh

# 只 baseline (10 轮)
sudo WITH_NOISE=0 ./run_perf_stat_batch_standalone.sh

# n1 单 VM 全 20 轮
sudo MODE=n1 ./run_perf_stat_batch_standalone.sh
```

## 3 种 oncpu 方法

| 方法 | 字段 | 来源 | 精度 | 干扰 |
|---|---|---|---|---|
| perf stat task-clock | `oncpu_task_clock_s` | `perf stat -e task-clock` 软件事件 | 毫秒级 | 单 perf 进程，开销极低 |
| perf stat cpu-clock | `oncpu_cpu_clock_s` | `perf stat -e cpu-clock` 软件事件 | 毫秒级 | 同上 |
| /proc/pid/stat | `oncpu_proc_stat_s` | utime+stime 差值 / CLK_TCK | 10ms (CLK_TCK) | 零（一次 cat，纳秒级）|

三种方法口径相同（target tid 在 CPU 上的总时间），采集机制完全独立。

## 采集时序

```
(background 启动 → 预热 10s)
(cluster noise 启动 → 预热 10s)
target READY (阻塞等 GO)
    │
    ├─ read /proc/<tid>/stat          ← 初始 utime/stime
    ├─ perf stat -t <tid> -e task-clock,cpu-clock &  ← 启动 perf stat
    │
    ├─ send GO                        ← target 开始 replay
    │   WALL_START = now()
    │
    │   ... target 跑 workload ...
    │
    ├─ wait "FC_TARGET_DONE"          ← target 完成
    │   WALL_END = now()
    │
    ├─ kill perf stat                 ← 停止采集
    ├─ read /proc/<tid>/stat          ← 最终 utime/stime
    │
    └─ stop_all_vms (background + noise + target)
```

perf stat 在 GO **之前**启动（不漏开头），DONE **之后**停止（不漏结尾）。

## 输出

每轮 run_dir 在 `../results_perf_stat/<时间戳>_<mode>_r<round>_<workload>_<pid>/`：

| 文件 | 说明 |
|---|---|
| `summary.txt` | 3 种 oncpu + wall_s + 配置摘要 |
| `result.env` | key=value 格式结果 |
| `perf_stat.txt` | perf stat 原始输出 |
| `perf_stdout.log` | perf stat stderr |
| `vm0_*.console.log` | target 串口日志 |
| `vm[1-3]_*.console.log` | background 串口日志 (n5) |
| `vm10[1-7]_*.console.log` | noise VM 串口日志 (有 noise 时) |
| `guest-init.sh` | 注入 guest 的 PID 1 脚本 |

batch 输出：

| 文件 | 说明 |
|---|---|
| `perf_stat_logs_<mode>/` | 每轮 log (tag = cfs_base / cfs_noise / fifo_base / fifo_noise) |
| `perf_stat_oncpu_<mode>.csv` | 对比表 |

对比表格式：
```
workload, mode, fifo, noise, wall_s, oncpu_task_clock_s, oncpu_cpu_clock_s, oncpu_proc_stat_s, oncpu_pct
```

## 脚本结构（494 行）

```
run_perf_stat_standalone.sh
│
├── 配置区 (line 27-50)
│   ├── 资源路径: FIRECRACKER_BIN / KERNEL_IMAGE / IMAGE_DIR
│   ├── CPU 拓扑: TARGET_CPU / HOUSEKEEPING_CPU
│   ├── cluster noise: CLUSTER_NOISE_CPUS / CLUSTER_NOISE_WORKLOAD / WARMUP
│   └── workload 表: 5 个 Python 包 name|ext4|repo|commit|replay
│
├── 工具函数 (line 84-121)
│   ├── read_utime_stime()  — 读 /proc/<tid>/stat
│   ├── wait_for_marker()   — 轮询 console log 等 marker
│   └── find_vcpu_tid()     — 遍历 /proc/<pid>/task/ 找 fc_vcpu 0
│
├── guest init (line 123-188)
│   └── generate_guest_init() — 内嵌完整 PID 1 脚本
│
├── firecracker 配置 + VM 启停 (line 190-337)
│   ├── generate_fc_config()   — JSON 配置
│   ├── make_boot_args()       — kernel cmdline
│   ├── launch_vm()            — 启动 VM (支持自定义 cpu + ext4)
│   ├── send_go()              — 发 GO
│   ├── start_cluster_noise()  — 启动 cluster noise VM (各绑指定核)
│   ├── stop_all_vms()         — 停所有 VM (background + noise + target)
│   └── cleanup()              — EXIT trap
│
└── 主流程 (line 339-494)
    ├── 启动 background (n5)
    ├── 启动 cluster noise (有 CLUSTER_NOISE_CPUS 时)
    ├── 启动 target + 查 tid + 设 FIFO
    ├── perf stat 启动 + /proc/stat 读初始值
    ├── GO → 等 DONE → 停 perf stat + 读最终值
    └── 计算并输出 3 种 oncpu
```

## 关键配置

| 变量 | 默认值 | 说明 |
|---|---|---|
| TARGET_CPU | 102 | Firecracker 绑核 |
| HOUSEKEEPING_CPU | 112 | 脚本/perf 绑核 |
| MEM_MIB | 1024 | VM 内存 (MiB) |
| MODE | n1 | n1(单VM) 或 n5(target+3background) |
| SCHED_FIFO | 0 | 1=启用 SCHED_FIFO/50 |
| CLUSTER_NOISE_CPUS | (空) | 逗号分隔的 CPU 列表，如 96,98,100,104,106,108,110 |
| CLUSTER_NOISE_WORKLOAD | joke2k__faker-2007 | noise VM 跑的 workload |
| CLUSTER_NOISE_WARMUP | 10 | noise 预热秒数 |
| FIRECRACKER_BIN | /opt/kata/bin/firecracker | firecracker 二进制 |
| KERNEL_IMAGE | $PERF_KVM_DIR/ub_latency/vmlinux-fc-arm64 | guest kernel |
| IMAGE_DIR | $PERF_KVM_DIR/ub_latency/ext4 | ext4 镜像目录 |

`PERF_KVM_DIR` 自动解析为 `SCRIPT_DIR/..`（即父目录 `perf_kvm/`）。

## CPU 拓扑

```
物理核  48   49   50   51   52   53   54   55   56
thread0 96   98  100  102  104  106  108  110  112
                              ↑               ↑
                         TARGET_CPU=102   HOUSEKEEPING_CPU=112
                         (Firecracker)    (脚本/perf 自己)
        ←── noise VM (7 台) ──→
```

- TARGET_CPU=102: target + background 全绑这里 (n5 时 4:1 超分)
- HOUSEKEEPING_CPU=112: 脚本 + perf stat 进程，不污染测量
- CLUSTER_NOISE_CPUS: 7 台 noise VM 各独占一核，产生 L3 cache 干扰
