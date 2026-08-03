# config.sh -- sourced by fc_sched_experiment.sh; do not run directly. (split from v17 cluster-noise)

# ============================== 可编辑配置区 ==================================

# Firecracker 二进制。这里只是直接执行该文件，不会启动 Kata runtime。
FIRECRACKER_BIN=${FIRECRACKER_BIN:-/opt/kata/bin/firecracker}

# 默认使用脚本同目录下、原裸 Firecracker 实验已经验证可启动的 guest
# kernel。若以后移动了 kernel，仍可用 KERNEL_IMAGE=/新路径覆盖。
KERNEL_IMAGE=${KERNEL_IMAGE:-$SCRIPT_DIR/vmlinux-fc-arm64}

# TARGET_CPU：所有 Firecracker 线程共同使用的实验核。
# HOUSEKEEPING_CPU：宿主机脚本和 perf 用户态进程使用的辅助核。
TARGET_CPU=${TARGET_CPU:-}
HOUSEKEEPING_CPU=${HOUSEKEEPING_CPU:-}

# 原实验把各 workload 的 base ext4 放在脚本同目录的 ext4/ 下。IMAGE_DIR
# 仍然允许通过环境变量覆盖，便于以后把大镜像迁到其他磁盘。
IMAGE_DIR=${IMAGE_DIR:-$SCRIPT_DIR/ext4}
RESULTS_DIR=${RESULTS_DIR:-$SCRIPT_DIR/results}

# 每台 microVM 固定为 1 个 vCPU；这里只允许调整内存。
MEM_MIB=${MEM_MIB:-1024}

# N=5 中，4 个 background 开始循环后预热多少秒，再启动 target。
BACKGROUND_WARMUP=${BACKGROUND_WARMUP:-10}

# 等待 guest READY 和等待 target 完成的超时时间。
READY_TIMEOUT=${READY_TIMEOUT:-90}
TARGET_TIMEOUT=${TARGET_TIMEOUT:-1800}

# perf 控制命令发出后，最多等待多少秒接收 ack。ack 表示 perf 已经真正完成
# enable/disable，而不是仅仅把命令写入了 FIFO。
PERF_CONTROL_TIMEOUT=${PERF_CONTROL_TIMEOUT:-5}

# 0：结束后删除临时 rootfs 副本；1：保留副本用于排错。
KEEP_DISKS=${KEEP_DISKS:-0}

# 1：保存 target 的 replay stdout/stderr 到每轮结果目录的 replay.log。
# 0：与旧版行为一致，target 和 background 的 replay 输出都丢弃。
# background 会无限循环 replay，因此无论此开关如何都不保存 background 输出。
SAVE_REPLAY_LOG=${SAVE_REPLAY_LOG:-1}

# target replay 日志在 guest tmpfs 中的空间上限（MiB）。tmpfs 避免将日志写入
# virtio rootfs，从而减少额外块设备 I/O 对 KVM/调度数据的影响。
REPLAY_LOG_MIB=${REPLAY_LOG_MIB:-64}

# KVM 原因事件与 sched_waking 的最大配对间隔（微秒）。
# KVM 定时器到期、虚拟 IRQ 注入和唤醒 vCPU 通常处于同一条同步内核调用链，
# 间隔远小于 500us。设置有限窗口可避免把前一个 background VM 的 KVM 事件
# 误归因给 target。该值会写入 run.env，便于复核。
WAKE_CAUSE_WINDOW_US=${WAKE_CAUSE_WINDOW_US:-500}

# 仅 n5_fifo 模式使用。Linux SCHED_FIFO 实时优先级范围为 1～99。
# 50 足以高于所有默认 CFS 线程，同时不会使用最高优先级，便于后续扩展。
# 脚本只对 target 的 fc_vcpu 0 TID 调用 chrt，不使用 chrt -a。
TARGET_FIFO_PRIORITY=${TARGET_FIFO_PRIORITY:-50}

# ---- cluster 噪声扩展（v17）------------------------------------------------
# 目的：在核0超分（n5）的基础上，于同 cluster 的其他核各跑一台 background
# 噪声 VM（循环 replay），制造 L3 竞争。perf 只采核0+target TID，噪声 VM 在
# 别的核上，不会被采入 perf.data，只通过共享 L3 拖慢 target。

# CORE0_BG：核0上的 background 数量。n5 默认 4；设 3 即复刻"3背景1测试"。
CORE0_BG=${CORE0_BG:-4}

# CLUSTER_NOISE_CPUS：噪声 VM 各自独占的核，逗号分隔，如 1,2,3,4,5,6,7。
# 留空表示不启用 cluster 噪声，退化为普通 n5/n5_fifo。
CLUSTER_NOISE_CPUS=${CLUSTER_NOISE_CPUS:-}

# CLUSTER_NOISE_WORKLOAD：噪声 VM 跑的 workload 名称，缺省用 target。
CLUSTER_NOISE_WORKLOAD=${CLUSTER_NOISE_WORKLOAD:-}

# 噪声 VM 起来后的额外预热秒数（叠加在 BACKGROUND_WARMUP 之后）。
CLUSTER_NOISE_WARMUP=${CLUSTER_NOISE_WARMUP:-10}
