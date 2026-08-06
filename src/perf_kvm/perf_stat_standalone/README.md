# perf_stat_standalone

独立 oncpu time 采集脚本，不依赖 v17 实验代码，用 `perf stat task-clock` + `/proc/<tid>/stat` 两种方法测量 target vCPU 的 oncpu time，与 v17 的 `sched:sched_switch` 切片累加做交叉验证。

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
| cluster noise | 支持（7 台 noise VM）| 不支持 |
| 代码量 | 2778 行 | 439 行 |

## 文件

| 文件 | 说明 |
|---|---|
| `run_perf_stat_standalone.sh` | 单次实验，启动 VM + perf stat 采集 |
| `run_perf_stat_batch_standalone.sh` | batch: 5 workload × (CFS+FIFO) = 10 轮 |

## 用法

### 单次实验

```bash
cd perf_stat_standalone

# CFS 超分 (target + 3 background)
sudo ./run_perf_stat_standalone.sh joke2k__faker-2007 n5

# FIFO 超分 (target 用 SCHED_FIFO/50)
sudo SCHED_FIFO=1 ./run_perf_stat_standalone.sh joke2k__faker-2007 n5

# CFS 单 VM (无 background)
sudo ./run_perf_stat_standalone.sh joke2k__faker-2007 n1
```

### batch 跑 10 轮

```bash
cd perf_stat_standalone
sudo ./run_perf_stat_batch_standalone.sh
```

跑 5 workload × (CFS + FIFO) = 10 轮，输出对比表。

## 3 种 oncpu 方法

| 方法 | 字段 | 来源 | 精度 | 干扰 |
|---|---|---|---|---|
| perf stat task-clock | `oncpu_task_clock_s` | `perf stat -e task-clock` 软件事件 | 毫秒级 | 单 perf 进程，开销极低 |
| perf stat cpu-clock | `oncpu_cpu_clock_s` | `perf stat -e cpu-clock` 软件事件 | 毫秒级 | 同上 |
| /proc/pid/stat | `oncpu_proc_stat_s` | utime+stime 差值 / CLK_TCK | 10ms (CLK_TCK) | 零（一次 cat，纳秒级）|

三种方法口径相同（target tid 在 CPU 上的总时间），采集机制完全独立。

## 采集时序

```
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
    └─ stop_all_vms
```

perf stat 在 GO **之前**启动（不漏开头），DONE **之后**停止（不漏结尾）。

## 输出

每轮 run_dir 在 `../results_perf_stat/<时间戳>_<mode>_r<round>_<workload>_<pid>/`：

| 文件 | 说明 |
|---|---|
| `summary.txt` | 3 种 oncpu + wall_s 摘要 |
| `result.env` | key=value 格式结果 |
| `perf_stat.txt` | perf stat 原始输出 |
| `perf_stdout.log` | perf stat stderr |
| `vm0_*.console.log` | target 串口日志 |
| `guest-init.sh` | 注入 guest 的 PID 1 脚本 |

batch 输出：
| 文件 | 说明 |
|---|---|
| `perf_stat_logs_<mode>/` | 每轮 log |
| `perf_stat_oncpu_<mode>.csv` | 对比表 |

对比表格式：
```
workload, mode, fifo, wall_s, oncpu_task_clock_s, oncpu_cpu_clock_s, oncpu_proc_stat_s, oncpu_pct
```

## 脚本结构（439 行）

```
run_perf_stat_standalone.sh
│
├── 配置区 (line 26-45)
│   ├── 资源路径: FIRECRACKER_BIN / KERNEL_IMAGE / IMAGE_DIR
│   ├── CPU 拓扑: TARGET_CPU / HOUSEKEEPING_CPU
│   └── workload 表: 5 个 Python 包 name|ext4|repo|commit|replay
│
├── 工具函数 (line 79-116)
│   ├── read_utime_stime()  — 读 /proc/<tid>/stat
│   ├── wait_for_marker()   — 轮询 console log 等 marker
│   └── find_vcpu_tid()     — 遍历 /proc/<pid>/task/ 找 fc_vcpu 0
│
├── guest init (line 118-183)
│   └── generate_guest_init() — 内嵌完整 PID 1 脚本
│
├── firecracker 配置 + VM 启停 (line 185-294)
│   ├── generate_fc_config() — JSON 配置
│   ├── make_boot_args()     — kernel cmdline
│   ├── launch_vm()          — 启动 VM (复制 ext4 + debugfs 注入 + 启动 + 等 READY + 绑核)
│   ├── send_go()            — 发 GO
│   ├── stop_all_vms()       — 停 VM
│   └── cleanup()            — EXIT trap
│
└── 主流程 (line 296-439)
    ├── 启动 background (n5)
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
| FIRECRACKER_BIN | /opt/kata/bin/firecracker | firecracker 二进制 |
| KERNEL_IMAGE | $PERF_KVM_DIR/ub_latency/vmlinux-fc-arm64 | guest kernel |
| IMAGE_DIR | $PERF_KVM_DIR/ub_latency/ext4 | ext4 镜像目录 |

`PERF_KVM_DIR` 自动解析为 `SCRIPT_DIR/..`（即父目录 `perf_kvm/`）。
