# SMT Firecracker 超分调度实验

基于 ARM 服务器 + Firecracker microVM，研究超分场景下调度策略（CFS vs SCHED_FIFO）对延迟敏感 Python 任务的影响，并提供 oncpu time 的多方法交叉验证。

## 环境要求

- ARM64 (aarch64) 服务器，openEuler / Linux 5.x+
- Firecracker 二进制 (`/opt/kata/bin/firecracker`)
- guest kernel (`ub_latency/vmlinux-fc-arm64`) + 5 个 Python 包的 ext4 镜像 (`ub_latency/ext4/`)
- root 权限（KVM / perf / chrt）
- 工具：perf, taskset, chrt, debugfs, python3, pandas+openpyxl（仅 Excel 导出需要）

## 目录结构

```
perf_kvm/
│
├── fc_sched_experiment_v17.sh          # 主实验单体 (2778 行)
├── fc_sched_experiment_v16.sh          # 历史版本
├── fc_sched_experiment.sh              # 旧单体 (1469 行)
├── run_cluster_noise_batch.sh          # batch: 5 workload × (baseline+noise)
├── run_multi_round.sh                  # 多轮: CFS 3 轮 + FIFO 3 轮
├── export_to_excel.py                  # 合并 summary.csv 出多 sheet xlsx
├── stats_multi_round.py                # 多轮统计 mean±stddev
├── cluster_noise/                      # 模块版 (与 v17 同逻辑, 拆成 lib/*.sh)
│   ├── fc_sched_experiment.sh
│   └── lib/ (12 个 .sh + 1 个 .awk)
│
└── perf_stat_standalone/               # 独立交叉验证 (不依赖 v17)
    ├── run_perf_stat_standalone.sh     # 单次实验 (439 行, 自包含)
    └── run_perf_stat_batch_standalone.sh # batch: 5 workload × (CFS+FIFO)
```

## 两套脚本的关系

| 维度 | v17 系列 (根目录) | perf_stat_standalone (子目录) |
|---|---|---|
| oncpu 采集方法 | `sched:sched_switch` tracepoint 切片累加 | `perf stat task-clock` + `/proc/pid/stat` |
| 采集机制 | perf kvm stat record + AWK 分析 | perf stat 软件事件 + 内核计数器 |
| 代码依赖 | batch 调用 v17 | 完全自包含, 不引用 v17 |
| 输出字段 | 60+ 字段 (slice/gap/voluntary/wakeup 原因等) | 3 种 oncpu + wall_s |
| 用途 | 主实验, 得出调度结论 | 交叉验证, 证明 oncpu 测量准确 |
| cluster noise | 支持 (7 台 noise VM) | 不支持 (简化) |

两套脚本独立运行, 互不引用代码。共用环境资源 (kernel + ext4 镜像)。

## 快速开始

### 跑 v17 主实验 (CFS + FIFO, 含 cluster noise)

```bash
cd ~/projects/SMT_firecracker/src/perf_kvm

# 单次 batch: 5 workload × (baseline+noise) = 10 轮
MODE=n5 ./run_cluster_noise_batch.sh          # CFS
MODE=n5_fifo ./run_cluster_noise_batch.sh     # FIFO

# 多轮 (3 轮 CFS + 3 轮 FIFO, 自动出统计)
nohup ./run_multi_round.sh 3 > multi_round.log 2>&1 &
tail -f multi_round.log

# 导出 Excel
pip install pandas openpyxl
python3 export_to_excel.py
```

### 跑独立 perf stat 交叉验证

```bash
cd ~/projects/SMT_firecracker/src/perf_kvm/perf_stat_standalone

# batch: 5 workload × (CFS+FIFO) = 10 轮
./run_perf_stat_batch_standalone.sh

# 或单次
./run_perf_stat_standalone.sh joke2k__faker-2007 n5            # CFS 超分
SCHED_FIFO=1 ./run_perf_stat_standalone.sh joke2k__faker-2007 n5  # FIFO 超分
./run_perf_stat_standalone.sh joke2k__faker-2007 n1            # CFS 单 VM
```

## 实验设计

### CPU 拓扑

```
物理核  48   49   50   51   52   53   54   55   56
thread0 96   98  100  102  104  106  108  110  112
                              ↑               ↑
                         TARGET_CPU=102   HOUSEKEEPING_CPU=112
                         (Firecracker)    (脚本/perf 自己)
        ←── noise VM (7 台) ──→
```

- TARGET_CPU=102: target + background 全绑这里, 5:1 超分
- HOUSEKEEPING_CPU=112: 脚本/perf 进程, 不污染测量
- NOISE_CPUS=96,98,100,104,106,108,110: cluster noise VM 各独占一核

### 一次实验的流程 (v17)

1. 启动 4 台 background VM, 进入循环 replay, 预热 10s
2. (可选) 启动 7 台 cluster noise VM, 预热
3. 启动 target VM, 查 fc_vcpu 0 tid, 设调度策略 (CFS 或 SCHED_FIFO/50)
4. perf record enable (control FIFO ack) → target GO → 等 DONE → perf disable
5. perf 落盘 → AWK 分析 → summary.csv (60+ 字段)

### oncpu time 三种采集方法

| 方法 | 来源 | 精度 | 干扰 |
|---|---|---|---|
| sched_switch 累加 (v17) | `perf kvm stat record` 的 sched_switch 切片 | 纳秒级 | perf record 带 filter, 开销低 |
| perf stat task-clock (standalone) | `perf stat -e task-clock` 软件事件 | 毫秒级 | 单 perf 进程, task-clock 开销极低 |
| /proc/pid/stat (standalone) | 内核 utime+stime 计数器差值 | CLK_TCK (10ms) | 零 (一次 cat, 纳秒级) |

三种方法口径相同 (target tid 在 CPU 上的总时间), 采集机制完全独立。若结果一致 (误差 < 5%), 证明 sched_switch 累加可信。

## 输出文件

### v17 系列

| 文件 | 说明 |
|---|---|
| `results/<时间戳>_<mode>_r<round>_<workload>_<pid>/` | 每轮 run_dir |
| `summary.csv` | 60+ 字段汇总 (一行) |
| `switch_out_events.csv` | 每次切出明细 |
| `kvm-stat-report.txt` | perf kvm stat report |
| `replay.log` | target replay stdout/stderr |
| `batch_logs_<mode>/` | batch 每轮的 v7 stdout log |
| `cluster_noise_table_<mode>.csv` | batch 汇总表 |
| `cluster_noise_summary.xlsx` | 多 sheet Excel (raw_long + compare + cross_mode) |
| `multi_round_stats.csv` | 多轮统计 mean±stddev |

### perf_stat_standalone

| 文件 | 说明 |
|---|---|
| `results_perf_stat/<时间戳>_<mode>_r<round>_<workload>_<pid>/` | 每轮 run_dir |
| `summary.txt` | 3 种 oncpu + wall_s 摘要 |
| `result.env` | key=value 格式结果 |
| `perf_stat.txt` | perf stat 原始输出 |
| `perf_stat_logs_<mode>/` | batch 每轮 log |
| `perf_stat_oncpu_<mode>.csv` | batch 对比表 |

## Workload 列表

| 名称 | Python 包 | ext4 镜像 |
|---|---|---|
| SpikeInterface__spikeinterface-1057 | SpikeInterface 0.96 | base-spikeinterface.ext4 |
| 12rambau__sepal_ui-747 | sepal_ui 2.15 | base-12rambau.ext4 |
| abhinavsingh__proxy.py-740 | proxy.py 2.3 | base-abhinavsingh.ext4 |
| mathandy__svgpathtools-170 | svgpathtools 1.4 | base-mathandy.ext4 |
| joke2k__faker-2007 | faker 24.2 | base-joke2k.ext4 |

每个 workload 在 guest 内执行 `git reset --hard <commit>` 后跑 `/generated_replay.sh`。

## 关键配置 (环境变量)

| 变量 | 默认值 | 说明 |
|---|---|---|
| TARGET_CPU | 102 | Firecracker 绑核 |
| HOUSEKEEPING_CPU | 112 | 脚本/perf 进程绑核 |
| CORE0_BG | 3 | background VM 数 (3 背景 + 1 target = 4 超分) |
| NOISE_CPUS | 96,98,100,104,106,108,110 | cluster noise VM 独占核 |
| MODE | n5 | 调度模式: n5 (CFS) 或 n5_fifo (SCHED_FIFO/50) |
| ROUND | 1 | 轮次编号 (标签, 不自动重跑) |
| SCHED_FIFO | 0 | standalone 脚本: 1=启用 SCHED_FIFO/50 |
| KERNEL_IMAGE | $PERF_KVM_DIR/ub_latency/vmlinux-fc-arm64 | guest kernel |
| IMAGE_DIR | $PERF_KVM_DIR/ub_latency/ext4 | ext4 镜像目录 |
