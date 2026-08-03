#!/usr/bin/env bash
# ==============================================================================
# fc_sched_experiment.sh
# 直接使用 Firecracker 的 N=1 / N=5 / N=5-FIFO 单核调度实验脚本
# ==============================================================================
#
# 一、实验要回答的问题
# ------------------------------------------------------------------------------
# 在 N=5 单核超分时，被观测 Firecracker vCPU 的“主动调出”为什么比 N=1 多：
#
#   1. 多出来的主动调出有多少次；
#   2. 其中多少由 guest 执行 WFI/WFE 引起；
#   3. 不能归因于 WFI/WFE 的 other 类型有多少；
#   4. WFI 后由什么事件唤醒：虚拟定时器、虚拟中断还是暂时无法归因；
#   5. 超分增加的是 vCPU 真正阻塞时间，还是唤醒后的就绪排队时间。
#
# 二、三种实验模式
# ------------------------------------------------------------------------------
# N=1：只启动被观测 microVM，被观测 workload 只执行一次。
#
# N=5：先启动 4 台 background microVM，每台 background 在 guest 内循环
#      replay；预热完成后再启动 target，target workload 只执行一次。
#      5 个完整 Firecracker 进程的全部宿主机线程共享 TARGET_CPU。
#
# N=5-FIFO：VM 数量、负载和绑核方式与 N=5 完全相同；只把 target 的
#           “fc_vcpu 0”线程设置为 SCHED_FIFO，其他所有 Firecracker
#           线程仍为 SCHED_OTHER（CFS）。该模式用于区分：
#
#             - 超分后增加的调出是否主要来自 CFS 对 target vCPU 的抢占；
#             - target vCPU 获得实时优先级后，WFI 次数及唤醒原因是否改变。
#
# 注意：FIFO 只是一项调度对照实验，不是生产配置建议。脚本不会修改宿主机
# sched_rt_runtime_us，也不会把 Firecracker 的其他线程迁出实验核。
#
# 三、主动/被动调出的判定
# ------------------------------------------------------------------------------
# 只分析 target 的 “fc_vcpu 0” 宿主机线程：
#
#   prev_state 以 R 开头：vCPU 仍可运行却被换下 CPU，记为被动调出
#                         （passive，通常就是被其他线程抢占）。
#
#   prev_state 不以 R 开头：vCPU 已睡眠/阻塞并放弃 CPU，记为主动调出
#                            （voluntary）。这里的“主动”是 Linux 调度意义
#                            上的 voluntary，不代表 guest 用户程序一定显式
#                            调用了 sched_yield。
#
# 对主动调出继续使用 KVM tracepoint 分类：
#   - guest 执行 WFI：wfi；
#   - guest 执行 WFE：wfe；
#   - 没有对应 WFI/WFE：other，并记录最近一次 kvm_exit 上下文。
#
# KVM 内部一次中断注入的 tracepoint 顺序不保证总是“IRQ -> sched_waking”。
# 当前 openEuler/KVM 上还会出现：
#
#   sched_waking -> sched_wakeup -> vgic_update_irq_pending -> sched_switch-in
#
# 因此唤醒原因必须在 sched_waking 前后双向匹配；只向前查找会把上述 IRQ
# 唤醒误报成 other。
#
# 四、单文件如何同时控制 guest
# ------------------------------------------------------------------------------
# 脚本内嵌了一个很小的 guest init。每次实验只把它注入临时 rootfs 副本，
# 不修改 base ext4。guest 启动后执行以下同步：
#
#   启动完成 -> 输出 FC_READY -> 等待宿主机发送 GO -> 执行 replay
#
# 宿主机侧的 perf 还会经过第二层同步：
#
#   perf 进程启动（事件禁用） -> enable 并等待 ack -> 发送 GO
#   target 输出 DONE          -> disable 并等待 ack -> 结束 perf
#   perf 完全停止             -> 导出 target replay 日志
#
# 因此 Firecracker boot、guest 初始化、git reset，以及 perf 初始化期间的
# READY 等待不会进入 perf.data。enable ack 到发送 GO 之间只保留记录起点和
# 写入串口 FIFO 两个必要操作，既把边界压到最小，也不会漏掉 replay 开头。
#
# 五、主要输出
# ------------------------------------------------------------------------------
#   summary.csv             调度、guest/Host 时间、阻塞/排队时间等汇总
#   switch_out_events.csv   每次调出、唤醒者、唤醒原因和后续调入的完整明细
#   wakeup_cause_summary.csv  本轮主动调出的唤醒原因计数与占比
#   perf.data               perf kvm stat record 产生的原始数据
#   perf.txt                perf script 转换后的文本
#   kvm-stat-report.txt     perf kvm stat report 的 target VM-exit 统计
#   threads.csv             各 Firecracker 宿主机线程及 TID
#   scheduling.csv          各线程的调度策略、实时优先级和 CPU 亲和性快照
#   replay.log              target workload 本轮 replay 的 stdout/stderr
#   *.console.log           各 microVM 的串口日志
#
# replay.log 的内容先写入 guest 内的 tmpfs；target 完成且 perf 停止后，才通过
# 串口传回宿主机。因此日志打印不会进入 perf.data。捕获 stdout/stderr 本身仍
# 会产生少量 guest 内存写入；若需要与旧版“输出丢弃”实验严格保持一致，可在
# 启动时设置 SAVE_REPLAY_LOG=0。
#
# ==============================================================================

set -Eeuo pipefail
export LC_ALL=C
shopt -u varredir_close 2>/dev/null || true

# 每次启动都会打印这个版本号和脚本的绝对路径。这样服务器上即使同时留有
# 多个同名副本，也能从实验日志直接确认真正执行的是哪一版。
SCRIPT_VERSION="2026-07-31-v17-cluster-noise"

readonly SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

if [[ -w /sys/fs/cgroup/cgroup.procs ]]; then
    echo $$ > /sys/fs/cgroup/cgroup.procs 2>/dev/null || true
fi

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

# workload 配置表，每行五列，以“|”分隔：
#   workload 名称 | base ext4 | guest 内仓库路径 | 固定 commit | replay 脚本
#
# ext4 使用相对路径时，相对于 IMAGE_DIR；也可以填写绝对路径。
# 新增或替换 workload 只修改这里，不需要修改后面的启动逻辑。
workload_table() {
    cat <<'TABLE'
SpikeInterface__spikeinterface-1057|base-spikeinterface.ext4|/workspace/SpikeInterface__spikeinterface__0.96|7268ab900443ca3f0239de3007352d05f2d7d875|/generated_replay.sh
12rambau__sepal_ui-747|base-12rambau.ext4|/workspace/12rambau__sepal_ui__2.15|a683a7665a9710acd5ca939308e18539e92014b7|/generated_replay.sh
abhinavsingh__proxy.py-740|base-abhinavsingh.ext4|/workspace/abhinavsingh__proxy.py__2.3|8052c907e8ed7bd889a13c8029a657675d6fd13a|/generated_replay.sh
mathandy__svgpathtools-170|base-mathandy.ext4|/workspace/mathandy__svgpathtools__1.4|c84c897bf2121ed86ceed45b4e027785351c2fd5|/generated_replay.sh
joke2k__faker-2007|base-joke2k.ext4|/workspace/joke2k__faker__24.2|250fa19baf01aa2289afe44b07225f785cf536c5|/generated_replay.sh
TABLE
}

# ============================= 运行期状态变量 =================================

# workload 配置解析后的结果：
#   ALL_WORKLOADS          表中所有 workload，保持表内顺序
#   CASE_WORKLOADS[0]      本轮 target
#   CASE_WORKLOADS[1..4]   N=5 时的四个 background
#   *_OF[workload名称]     根据名称查询对应配置
declare -a ALL_WORKLOADS CASE_WORKLOADS
declare -A ROOTFS_OF GUEST_REPO_OF COMMIT_OF REPLAY_OF

# VM 运行期信息。这里不用“对象”或复杂数据结构，只使用相同下标关联数据：
#   VM_PROCESS_PID[0] 与 VM_CONSOLE_LOG[0] 都属于 target；
#   N=5 时，下标 1～4 属于四个 background。
declare -a VM_PROCESS_PID VM_INPUT_FD VM_CONSOLE_LOG
declare -a VM_ROOTFS VM_API_SOCKET VM_STDIN_FIFO

# cluster 噪声 VM 的运行期信息，与核0 VM 数组平行但独立下标，避免和 perf 过滤
# 用的 target/background 编号混在一起。NOISE_CPU[$i] 记录该 VM 独占的核。
declare -a NOISE_PID=() NOISE_CPU=() NOISE_WL=() NOISE_ROOTFS=() NOISE_CONSOLE_LOG
declare -a NOISE_INPUT_FD=() NOISE_API_SOCKET=() NOISE_STDIN_FIFO=()
CLUSTER_NOISE_CPU_LIST=()
NOISE_COUNT=0

# 当前实验的公共状态。函数之间需要共享这些值，因此不声明为局部变量。
EXPERIMENT_MODE=
TARGET_WORKLOAD=
ROUND_ID=
RUN_DIR=
TARGET_VCPU_TID=
PERF_RECORD_PID=
PERF_CONTROL_FD=
PERF_ACK_FD=
PERF_CONTROL_FIFO=
PERF_ACK_FIFO=
PERF_EVENTS_ENABLED=0
PERF_DISABLE_ACK_MS=
WINDOW_START_TIME=
WINDOW_END_TIME=
TARGET_EXIT_CODE=
TARGET_SCHED_POLICY=
TARGET_SCHED_PRIORITY=
HOST_SCHED_RT_PERIOD_US=
HOST_SCHED_RT_RUNTIME_US=

log() { printf '[fc-exp] %s\n' "$*"; }
die() { printf '[fc-exp] ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<EOF
运行一个实验 case：
  sudo env TARGET_CPU=102 HOUSEKEEPING_CPU=0 \\
    $0 run <n1|n5|n5_fifo> <target-workload> <round>

默认资源位置（均相对于本脚本）：
  kernel：$SCRIPT_DIR/vmlinux-fc-arm64
  ext4：  $SCRIPT_DIR/ext4/base-*.ext4
  如文件位于其他目录，可用 KERNEL_IMAGE 和 IMAGE_DIR 环境变量覆盖。

日志：
  默认保存 target replay 的 stdout/stderr 到每轮结果目录的 replay.log。
  如需与旧版丢弃输出的行为严格一致，启动时设置 SAVE_REPLAY_LOG=0。

参数含义：
  n1               单 VM，全部线程使用默认 CFS
  n5               五台完整 VM 共享一个宿主机 CPU，全部线程使用默认 CFS
  n5_fifo          与 n5 相同，但仅 target 的 fc_vcpu 0 使用 SCHED_FIFO
  target-workload  workload_table 中被观测任务的名称
  round            重复实验的轮次编号，例如 1、2、3

FIFO 优先级：
  n5_fifo 默认使用实时优先级 50，可通过 TARGET_FIFO_PRIORITY=数值覆盖。
  允许范围为 1～99。脚本会逐线程验证，确保只有 target vCPU 是 FIFO。

比较同一个 target、同一个 round：
  $0 compare <n1-summary.csv> <n5-summary.csv> [comparison.csv]
  $0 compare <n5-summary.csv> <n5_fifo-summary.csv> [comparison.csv]

只取/对比 target 的墙钟耗时（wall_s，即"action 总耗时"）：
  $0 walltime <summary.csv>                          # 打印 workload/round/wall_s
  $0 walltime <噪声summary.csv> <baseline_summary.csv>  # 输出 baseline/噪声/delta 一行

cluster 噪声（v17 新增，仅在 n5/n5_fifo 下生效，默认关闭）：
  sudo env TARGET_CPU=0 HOUSEKEEPING_CPU=8 \\
        CORE0_BG=3 CLUSTER_NOISE_CPUS=1,2,3,4,5,6,7 \\
        CLUSTER_NOISE_WORKLOAD=joke2k__faker-2007 \\
        $0 run n5 <target-workload> <round>
    CORE0_BG            核0 background 数（默认 4；设 3 即"3背景1测试"）
    CLUSTER_NOISE_CPUS  各噪声 VM 独占的核，逗号分隔（留空=不启用）
    CLUSTER_NOISE_WORKLOAD  噪声 VM 跑的 workload（缺省用 target）
    CLUSTER_NOISE_WARMUP    噪声额外预热秒数（默认 10）

只重新分析已经采集完成的结果，不重新启动 VM：
  sudo env KERNEL_IMAGE=/实际路径/vmlinux-fc-arm64 \\
    $0 analyze <run_dir>

新版本生成的 run.env 会记录 kernel_image，后续重新分析时通常不必再次指定。
旧版本结果没有该字段，且 kernel 不在脚本默认位置时，需要显式传 KERNEL_IMAGE。
EOF
}

# n5 和 n5_fifo 都会启动 5 台完整 microVM。把判断集中在一个函数里，
# 避免后续新增步骤时漏掉 FIFO 模式。
is_five_vm_mode() {
    [[ ${EXPERIMENT_MODE:-} == n5 || ${EXPERIMENT_MODE:-} == n5_fifo ]]
}

# cluster 噪声仅在 5-VM 模式（核0超分）下才有意义：单独 n1 加噪声无法体现
# "超分+L3竞争"的组合。这里也只在此模式下启动噪声。
is_cluster_noise_enabled() {
    is_five_vm_mode && [[ -n ${CLUSTER_NOISE_CPUS:-} ]]
}

# 把 workload_table 转换成 Bash 数组，后续代码即可按名称查询配置。
load_workload_table() {
    local name image repo commit replay extra
    while IFS='|' read -r name image repo commit replay extra; do
        [[ -n $name ]] || continue
        [[ -n $image && -n $repo && -n $commit && -n $replay && -z ${extra:-} ]] || \
            die "workload 配置行格式错误: $name"
        [[ $name =~ ^[A-Za-z0-9_.-]+$ ]] || die "workload 名称含不安全字符: $name"
        [[ $repo != *[[:space:]]* && $commit != *[[:space:]]* && $replay != *[[:space:]]* ]] || \
            die "guest 路径或 commit 不能包含空白字符: $name"
        [[ $image == /* ]] || image="$IMAGE_DIR/$image"
        ALL_WORKLOADS+=("$name")
        ROOTFS_OF[$name]=$image GUEST_REPO_OF[$name]=$repo COMMIT_OF[$name]=$commit REPLAY_OF[$name]=$replay
    done < <(workload_table)
}

# 决定本轮 VM 组成：target 固定为下标 0；N=5 时再取前 CORE0_BG 个非 target
# 作为核0 background。CORE0_BG 可配，默认 4（原 n5）；设 3 即"3背景1测试"。
select_case_workloads() {
    local name added=0
    [[ -n ${ROOTFS_OF[$TARGET_WORKLOAD]+yes} ]] || \
        die "workload 配置表中没有 target: $TARGET_WORKLOAD"
    CASE_WORKLOADS=("$TARGET_WORKLOAD")
    if is_five_vm_mode; then
        [[ $CORE0_BG =~ ^[1-9][0-9]*$ ]] || die "CORE0_BG 必须是正整数"
        for name in "${ALL_WORKLOADS[@]}"; do
            (( added < CORE0_BG )) || break
            [[ $name != "$TARGET_WORKLOAD" ]] && { CASE_WORKLOADS+=("$name"); added=$((added+1)); }
        done
        (( added == CORE0_BG )) || \
            die "核0 background 数量不足：需要 CORE0_BG=$CORE0_BG，实际可选 $added"
        ((${#CASE_WORKLOADS[@]} >= 2)) || die "N=5 至少需要 1 个 background"
    fi
}

find_tracepoint_directory() {
    local path
    for path in /sys/kernel/tracing/events /sys/kernel/debug/tracing/events; do
        [[ -d $path ]] && { printf '%s\n' "$path"; return; }
    done
    return 1
}

# 正式创建 VM 前一次性检查命令、CPU、KVM、tracepoint 和 rootfs。
check_environment() {
    local command event name tracefs perf_record_help sysctl_file
    [[ $(id -u) -eq 0 ]] || die "采集必须以 root 运行"
    [[ -x $FIRECRACKER_BIN ]] || die "Firecracker 不存在或不可执行: $FIRECRACKER_BIN"
    [[ -f $KERNEL_IMAGE ]] || die "guest kernel 不存在: $KERNEL_IMAGE"
    [[ -r /dev/kvm && -w /dev/kvm ]] || die "/dev/kvm 不可读写"
    [[ $TARGET_CPU =~ ^[0-9]+$ && $HOUSEKEEPING_CPU =~ ^[0-9]+$ ]] || \
        die "TARGET_CPU 和 HOUSEKEEPING_CPU 必须是整数"
    [[ $TARGET_CPU != "$HOUSEKEEPING_CPU" ]] || die "实验核和 housekeeping 核不能相同"
    [[ -d /sys/devices/system/cpu/cpu$TARGET_CPU ]] || die "CPU $TARGET_CPU 不存在"
    [[ -d /sys/devices/system/cpu/cpu$HOUSEKEEPING_CPU ]] || die "CPU $HOUSEKEEPING_CPU 不存在"

    for sysctl_file in \
        /proc/sys/kernel/sched_rt_period_us \
        /proc/sys/kernel/sched_rt_runtime_us
    do
        [[ -r $sysctl_file ]] || die "无法读取宿主机实时调度配置: $sysctl_file"
    done

    for command in perf awk debugfs taskset chrt renice grep sed date cp mkfifo \
                   readlink sha256sum tail tee sleep; do
        command -v "$command" >/dev/null || die "缺少命令: $command"
    done

    # 本实验依赖 perf 的运行期控制接口。旧版 perf 没有 --control 时，若继续
    # 执行就只能把 READY 等待也录进 perf.data，因此在创建 VM 前明确失败。
    perf_record_help=$(perf record -h 2>&1 || true)
    [[ $perf_record_help == *--control* && $perf_record_help == *--delay* ]] || \
        die "当前 perf 不支持 --control/--delay=-1，请升级 perf 后再运行"

    tracefs=$(find_tracepoint_directory) || die "未找到 tracefs events 目录"
    # v15 不只判断“是不是 WFI”，还要把 WFI 后的阻塞、唤醒和重新调入串起来。
    # 这里只检查脚本实际会录制的事件，缺任意一个都在启动 VM 前停止。
    for event in \
        sched/sched_switch \
        sched/sched_waking \
        sched/sched_wakeup \
        kvm/kvm_entry \
        kvm/kvm_exit \
        kvm/kvm_wfx_arm64 \
        kvm/kvm_vcpu_wakeup \
        kvm/kvm_timer_hrtimer_expire \
        kvm/kvm_timer_emulate \
        kvm/kvm_timer_update_irq \
        kvm/kvm_irq_line \
        kvm/vgic_update_irq_pending
    do
        [[ -r $tracefs/$event/id ]] || die "内核缺少 tracepoint: ${event/\//:}"
    done
    for name in "${CASE_WORKLOADS[@]}"; do
        [[ -f ${ROOTFS_OF[$name]} ]] || die "base ext4 不存在: ${ROOTFS_OF[$name]}"
    done
}

# ============================ 内嵌 guest init ================================

write_guest_init() {
    local output=$1
    cat >"$output" <<'GUEST_INIT'
#!/bin/bash
# 这段脚本在 guest 内作为 PID 1 运行。
# 它只负责三件事：准备最小运行环境、等待宿主机 GO、按角色执行 replay。
#
# 不在 PID 1 上启用 nounset（set -u）。各 workload 镜像中的 Conda 版本并不
# 完全相同，部分 conda.sh 会有意读取尚未设置的变量；若 PID 1 开着 nounset，
# 这种兼容性差异会直接结束 init，随后内核只能报“Attempted to kill init”。
# 下面已经逐一校验了所有必需的 fc_* 参数，因此关闭 nounset 不会掩盖参数缺失。
set +u

# PID 1 启动时需要手动挂载这些伪文件系统，否则 git、进程查询和串口等
# 基础功能可能无法正常工作。
mount -t proc proc /proc 2>/dev/null || true
mount -t sysfs sysfs /sys 2>/dev/null || true
mount -t devtmpfs devtmpfs /dev 2>/dev/null || true
mkdir -p /dev/pts /run /tmp
mount -t devpts devpts /dev/pts 2>/dev/null || true

# 将标准输入、输出和错误全部接到 Firecracker 串口：
#   guest 用 echo 向宿主机报告状态；
#   宿主机通过串口输入 FIFO 发送 GO。
exec </dev/ttyS0 >/dev/ttyS0 2>&1

# 从 /proc/cmdline 中读取宿主机通过 boot_args 传进来的 fc_* 参数。
boot_value() {
    local key=$1 item
    for item in $(cat /proc/cmdline); do
        case $item in "$key"=*) printf '%s\n' "${item#*=}"; return ;; esac
    done
    return 1
}

ROLE=$(boot_value fc_role || true)
NAME=$(boot_value fc_name || true)
REPO=$(boot_value fc_repo || true)
COMMIT=$(boot_value fc_commit || true)
REPLAY=$(boot_value fc_replay || true)
SAVE_REPLAY_LOG=$(boot_value fc_save_replay_log || true)
REPLAY_LOG_MIB=$(boot_value fc_replay_log_mib || true)

# 出错后不直接退出 PID 1，避免内核 panic 淹没真正错误；串口会保留
# FC_ERROR，宿主机最终因等待 READY 超时而停止本轮实验。
fail() {
    echo "FC_ERROR role=${ROLE:-unknown} name=${NAME:-unknown} message=$*"
    while true; do sleep 3600; done
}

[[ $ROLE == target || $ROLE == background ]] || fail invalid_role
[[ -d $REPO/.git ]] || fail "repo_not_found:$REPO"
[[ -f $REPLAY ]] || fail "replay_not_found:$REPLAY"
[[ $SAVE_REPLAY_LOG == 0 || $SAVE_REPLAY_LOG == 1 ]] || fail invalid_save_replay_log
[[ $REPLAY_LOG_MIB =~ ^[1-9][0-9]*$ ]] || fail invalid_replay_log_mib

# 只为 target 创建日志 tmpfs。background 会无限循环 replay，保存其完整输出
# 会让日志无界增长，因此 background 始终保持静默。
TARGET_REPLAY_LOG=/run/fc-exp/replay.log
if [[ $ROLE == target && $SAVE_REPLAY_LOG == 1 ]]; then
    mkdir -p /run/fc-exp
    mount -t tmpfs -o "size=${REPLAY_LOG_MIB}m,mode=0700" \
        fc-replay-log /run/fc-exp 2>/dev/null || fail replay_log_tmpfs_mount_failed
fi

# 尽量复现 workload 镜像中的 Python/Conda 执行环境。
export HOME=/root USER=root LOGNAME=root SHELL=/bin/bash
export PATH=/opt/miniconda3/envs/testbed/bin:/opt/miniconda3/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PYTHONUNBUFFERED=1 PIP_BREAK_SYSTEM_PACKAGES=1
if [[ -f /opt/miniconda3/etc/profile.d/conda.sh ]]; then
    # PATH 已经显式指向 testbed 环境，所以 activate 失败时仍可继续执行。
    # 不再吞掉失败：把一条简短告警留在串口日志中，便于区分环境差异。
    source /opt/miniconda3/etc/profile.d/conda.sh >/dev/null 2>&1 || \
        echo "FC_WARNING role=$ROLE name=$NAME message=conda_source_failed"
    conda activate testbed >/dev/null 2>&1 || \
        echo "FC_WARNING role=$ROLE name=$NAME message=conda_activate_failed"
fi

reset_repo() { git -C "$REPO" reset --hard "$COMMIT" >/dev/null 2>&1; }

# background 无限循环，继续丢弃 stdout/stderr。
run_replay_silent() {
    (cd "$REPO" && /bin/bash "$REPLAY") </dev/null >/dev/null 2>&1
}

# target 仅执行一次。启用日志时先写到 guest tmpfs，不在测量窗口内打印串口。
run_target_replay() {
    if [[ $SAVE_REPLAY_LOG == 1 ]]; then
        (cd "$REPO" && /bin/bash "$REPLAY") \
            </dev/null >"$TARGET_REPLAY_LOG" 2>&1
    else
        run_replay_silent
    fi
}

# 在报告 READY 前恢复到固定 commit。因此 target 的 git reset 不会被
# 计入 perf 测量窗口；background 每轮结束后也会恢复相同初始状态。
reset_repo || fail reset_failed
echo "FC_READY role=$ROLE name=$NAME"

# 此处阻塞是实验同步屏障。只有宿主机确认绑核、背景预热和 perf 就绪后，
# 才会向对应 VM 写入 GO。
IFS= read -r command
[[ $command == GO ]] || fail expected_GO

if [[ $ROLE == background ]]; then
    # background VM 只启动一次，随后在同一个 guest 内循环 replay。
    # 不在宿主机反复重启 VM，避免把 boot/销毁开销混入背景噪声。
    echo "FC_BACKGROUND_STARTED name=$NAME"
    while true; do
        run_replay_silent || true
        reset_repo || fail reset_failed
    done
fi

# target 只执行一次。BEGIN/DONE 是宿主机确定采集窗口和返回码的标记。
echo "FC_TARGET_BEGIN name=$NAME"
run_target_replay
rc=$?
echo "FC_TARGET_DONE name=$NAME rc=$rc"

# DONE 后绝不执行第二轮 replay。启用日志时，宿主机会先停止 perf，再发送
# DUMP_REPLAY_LOG；此后才把日志打印到串口，所以日志传输不会进入 perf.data。
if [[ $SAVE_REPLAY_LOG == 1 ]]; then
    IFS= read -r command || true
    [[ $command == DUMP_REPLAY_LOG ]] || fail expected_DUMP_REPLAY_LOG

    echo "FC_REPLAY_LOG_BEGIN name=$NAME"
    cat "$TARGET_REPLAY_LOG"
    # replay 输出不一定以换行结束，先补一个换行，保证 END 标记单独成行。
    printf '\nFC_REPLAY_LOG_END name=%s\n' "$NAME"
else
    IFS= read -r _ || true
fi

# 日志导出后继续阻塞，等待宿主机终止 Firecracker。
while true; do sleep 3600; done
GUEST_INIT
    chmod 0755 "$output"
}

# ========================== VM 生命周期与资源清理 =============================

# 关闭 perf 的两个控制 FD，并删除对应 FIFO。
# FD 必须在 perf 退出后再关；否则 perf 可能把控制通道 EOF 当成异常。
close_perf_control_channel() {
    if [[ ${PERF_CONTROL_FD:-} =~ ^[0-9]+$ ]]; then
        exec {PERF_CONTROL_FD}>&- || true
    fi
    if [[ ${PERF_ACK_FD:-} =~ ^[0-9]+$ ]]; then
        exec {PERF_ACK_FD}>&- || true
    fi

    [[ -n ${PERF_CONTROL_FIFO:-} ]] && rm -f -- "$PERF_CONTROL_FIFO"
    [[ -n ${PERF_ACK_FIFO:-} ]] && rm -f -- "$PERF_ACK_FIFO"
    PERF_CONTROL_FD=
    PERF_ACK_FD=
    PERF_CONTROL_FIFO=
    PERF_ACK_FIFO=
}

# 向已启动的 perf 发送一条控制命令，并等待它返回“ack”。
#
# 仅仅把 enable 写进 FIFO 不代表事件已经启用。必须等到 ack 后再发送 guest
# GO，否则两条异步路径之间存在竞争，短任务的开头可能在 perf 真正启用前
# 已经执行完毕。
send_perf_control_command() {
    local control_command=$1 acknowledgment=

    [[ -n ${PERF_RECORD_PID:-} ]] && kill -0 "$PERF_RECORD_PID" 2>/dev/null || return 1
    [[ ${PERF_CONTROL_FD:-} =~ ^[0-9]+$ ]] || return 1
    [[ ${PERF_ACK_FD:-} =~ ^[0-9]+$ ]] || return 1

    printf '%s\n' "$control_command" >&"$PERF_CONTROL_FD" || return 1
    IFS= read -r -t "$PERF_CONTROL_TIMEOUT" -u "$PERF_ACK_FD" acknowledgment || return 1
    [[ $acknowledgment == ack ]]
}

# 正常结束 perf：若事件仍启用则先尽力 disable，再发送 SIGINT 并 wait，确保
# 环形缓冲区完整写入 perf.data。cleanup 也会调用本函数，所以失败路径不能
# 在这里再次 die。
stop_perf_recording() {
    if [[ -n ${PERF_RECORD_PID:-} ]] && kill -0 "$PERF_RECORD_PID" 2>/dev/null; then
        if [[ ${PERF_EVENTS_ENABLED:-0} == 1 ]]; then
            send_perf_control_command disable || \
                log "警告：清理阶段未收到 perf disable ack，将直接结束 perf"
            PERF_EVENTS_ENABLED=0
        fi

        kill -INT "$PERF_RECORD_PID" 2>/dev/null || true
        wait "$PERF_RECORD_PID" 2>/dev/null || true
    fi
    PERF_RECORD_PID=
    PERF_EVENTS_ENABLED=0
    close_perf_control_channel
}

# 停止本轮创建的全部 Firecracker 进程。
# 先给 TERM 留出很短的正常退出时间，再用 KILL 兜底，最后 wait 回收进程。
stop_all_vms() {
    local pid
    for pid in "${VM_PROCESS_PID[@]:-}"; do
        [[ -n $pid ]] || continue
        kill -TERM "$pid" 2>/dev/null || true
    done
    sleep 0.2
    for pid in "${VM_PROCESS_PID[@]:-}"; do
        [[ -n $pid ]] || continue
        kill -KILL "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    done
}

# ====================== cluster 噪声 VM（v17）================================
# 噪声 VM 与核0 VM 互相独立：各自独占一个噪声核，角色恒为 background，
# 在 guest 内无限循环 replay。它们不进入 perf 的 target TID 过滤，也不会
# 被 analyze 当作核0 background 处理。

# 解析 CLUSTER_NOISE_CPUS 为数组，并校验每个核有效、且不与实验核/辅助核冲突。
parse_cluster_noise_cpus() {
    CLUSTER_NOISE_CPU_LIST=()
    is_cluster_noise_enabled || return 0
    local raw cpu
    IFS=',' read -ra raw <<<"$CLUSTER_NOISE_CPUS"
    for cpu in "${raw[@]}"; do
        [[ $cpu =~ ^[0-9]+$ ]] || die "CLUSTER_NOISE_CPUS 含非数字项: $cpu"
        [[ $cpu != "$TARGET_CPU" ]] || \
            die "cluster 噪声核不能等于 TARGET_CPU=$TARGET_CPU"
        [[ $cpu != "$HOUSEKEEPING_CPU" ]] || \
            die "cluster 噪声核不能等于 HOUSEKEEPING_CPU=$HOUSEKEEPING_CPU"
        [[ -d /sys/devices/system/cpu/cpu$cpu ]] || die "cluster 噪声核不存在: cpu$cpu"
        CLUSTER_NOISE_CPU_LIST+=("$cpu")
    done
    ((${#CLUSTER_NOISE_CPU_LIST[@]} > 0)) || die "CLUSTER_NOISE_CPUS 解析后为空"
}

# 启动一台噪声 VM，绑定到指定核。结构与 launch_vm 一致，但 workload 与 CPU
# 由参数显式指定，且角色固定为 background、save_replay_log 固定为 0。
launch_cluster_noise_vm() {
    local idx=$1 cpu=$2 workload=$3
    local rootfs_copy config_file stdin_fifo console_log api_socket input_fd
    local firecracker_pid kernel_boot_args task_directory thread_id allowed_cpus thread_name

    rootfs_copy="$RUN_DIR/work/noise_${idx}_${workload}.ext4"
    config_file="$RUN_DIR/noise_${idx}_${workload}.json"
    stdin_fifo="$RUN_DIR/work/noise_${idx}.stdin"
    console_log="$RUN_DIR/noise_${idx}_${workload}.console.log"
    api_socket="/tmp/fc-exp-noise-${$}-${idx}.sock"

    NOISE_ROOTFS[$idx]=$rootfs_copy
    NOISE_API_SOCKET[$idx]=$api_socket
    NOISE_STDIN_FIFO[$idx]=$stdin_fifo
    NOISE_CONSOLE_LOG[$idx]=$console_log
    NOISE_CPU[$idx]=$cpu
    NOISE_WL[$idx]=$workload

    log "准备 noise VM[$idx] cpu=$cpu workload=$workload"
    cp --reflink=auto --sparse=always "${ROOTFS_OF[$workload]}" "$rootfs_copy"
    install_guest_init "$rootfs_copy" "$RUN_DIR/guest-init.sh" "$RUN_DIR/debugfs.log"

    kernel_boot_args="keep_bootcon console=ttyS0 reboot=k panic=1 pci=off root=/dev/vda rw rootwait"
    kernel_boot_args+=" init=/fc-exp-init.sh fc_role=background fc_name=$workload"
    kernel_boot_args+=" fc_repo=${GUEST_REPO_OF[$workload]}"
    kernel_boot_args+=" fc_commit=${COMMIT_OF[$workload]}"
    kernel_boot_args+=" fc_replay=${REPLAY_OF[$workload]}"
    kernel_boot_args+=" fc_save_replay_log=0 fc_replay_log_mib=64"
    write_firecracker_config "$config_file" "$rootfs_copy" "$kernel_boot_args"

    rm -f -- "$api_socket"
    mkfifo "$stdin_fifo"
    exec {input_fd}<>"$stdin_fifo"

    taskset -c "$cpu" "$FIRECRACKER_BIN" \
        --api-sock "$api_socket" --config-file "$config_file" \
        <&"$input_fd" >"$console_log" 2>&1 &
    firecracker_pid=$!

    NOISE_PID[$idx]=$firecracker_pid
    NOISE_INPUT_FD[$idx]=$input_fd

    wait_for_console_marker "$console_log" \
        "FC_READY role=background name=$workload" "$firecracker_pid" "$READY_TIMEOUT" || {
        tail -80 "$console_log" >&2 || true
        die "noise VM 未进入 READY: $workload cpu=$cpu"
    }

    # 绑核并逐线程核验：噪声 VM 全部线程必须在指定噪声核，且为 SCHED_OTHER。
    taskset -a -pc "$cpu" "$firecracker_pid" >/dev/null
    chrt -a -o -p 0 "$firecracker_pid" >/dev/null
    for task_directory in /proc/"$firecracker_pid"/task/*; do
        thread_id=${task_directory##*/}
        renice -n 0 -p "$thread_id" >/dev/null
        allowed_cpus=$(awk '/^Cpus_allowed_list:/{print $2}' "$task_directory/status")
        [[ $allowed_cpus == "$cpu" ]] || \
            die "noise VM 绑核失败: tid=$thread_id 实际=$allowed_cpus 预期=$cpu"
        thread_name=$(<"$task_directory/comm")
        printf 'noise_%s,%s,%s,%s,%s\n' \
            "$idx" "$workload" "$firecracker_pid" "$thread_id" "$thread_name" \
            >>"$RUN_DIR/threads.csv"
    done
    log "noise VM[$idx] 已就绪 cpu=$cpu workload=$workload pid=$firecracker_pid"
}

# 启动全部噪声 VM 并让它们进入循环。返回时噪声已在各核上稳定跑 replay。
start_cluster_noise() {
    is_cluster_noise_enabled || return 0
    local idx cpu workload
    idx=0
    for cpu in "${CLUSTER_NOISE_CPU_LIST[@]}"; do
        workload=${CLUSTER_NOISE_WORKLOAD:-$TARGET_WORKLOAD}
        [[ -n ${ROOTFS_OF[$workload]+yes} ]] || \
            die "cluster 噪声 workload 不在配置表: $workload"
        launch_cluster_noise_vm "$idx" "$cpu" "$workload"
        idx=$((idx+1))
    done
    NOISE_COUNT=$idx

    # 先全部发 GO，再等每台都报告 FC_BACKGROUND_STARTED，避免一台卡住拖累启动。
    for ((idx=0; idx<NOISE_COUNT; idx++)); do
        printf 'GO\n' >&"${NOISE_INPUT_FD[$idx]}"
    done
    for ((idx=0; idx<NOISE_COUNT; idx++)); do
        wait_for_console_marker "${NOISE_CONSOLE_LOG[$idx]}" \
            "FC_BACKGROUND_STARTED name=${NOISE_WL[$idx]}" \
            "${NOISE_PID[$idx]}" "$READY_TIMEOUT" || \
            die "noise VM 未开始循环: ${NOISE_WL[$idx]} cpu=${NOISE_CPU[$idx]}"
    done
    log "cluster 噪声已就绪 count=$NOISE_COUNT cpus=${CLUSTER_NOISE_CPUS}"
}

# 停止全部噪声 VM。与 stop_all_vms 同样的 TERM->KILL->wait 顺序。
stop_cluster_noise_vms() {
    [[ ${#NOISE_PID[@]} -eq 0 ]] && return 0
    local idx pid
    for ((idx=0; idx<${#NOISE_PID[@]}; idx++)); do
        pid=${NOISE_PID[$idx]:-}
        [[ -n $pid ]] || continue
        kill -TERM "$pid" 2>/dev/null || true
    done
    sleep 0.2
    for ((idx=0; idx<${#NOISE_PID[@]}; idx++)); do
        pid=${NOISE_PID[$idx]:-}
        [[ -n $pid ]] || continue
        kill -KILL "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    done
}

# N=5 的 background 会无限循环 replay，即使 target 已经完成，也会继续在
# TARGET_CPU 上产生 KVM tracepoint。当前 openEuler perf 在持续事件流下可能
# 长时间不处理 control FIFO 中的 disable，导致采集窗口不能及时关闭。
#
# 因此只在已经看到 FC_TARGET_DONE 之后暂停四台 background。此时被观测
# workload 已经结束，不会改变实验阶段的竞争关系；暂停产生的 background
# 调度事件也不会通过 target TID 过滤。background 无需恢复，稍后由清理流程
# 直接终止。N=1 不执行任何操作。
pause_background_vms_before_perf_disable() {
    is_five_vm_mode || return 0

    local vm_index background_pid
    for ((vm_index=1; vm_index<${#VM_PROCESS_PID[@]}; vm_index++)); do
        background_pid=${VM_PROCESS_PID[$vm_index]:-}
        [[ -n $background_pid ]] || continue
        kill -0 "$background_pid" 2>/dev/null || \
            die "关闭 perf 前发现 background 已退出: pid=$background_pid"
        kill -STOP "$background_pid" || \
            die "无法暂停 background Firecracker: pid=$background_pid"
    done

    log "target 已完成，${CORE0_BG:-4} 台 background 已暂停，开始关闭 perf 采集窗口"
}

# 无论正常结束、命令失败还是用户按 Ctrl-C，都会进入这里。
# 清理顺序是：停止采集 -> 停止 VM -> 关闭 FIFO -> 删除临时文件。
cleanup_generated_resources() {
    local original_exit_code=$? path file_descriptor
    trap - EXIT INT TERM

    stop_perf_recording
    stop_all_vms
    stop_cluster_noise_vms

    # 每个 FIFO 都被宿主机以“读写”方式打开；关闭相应 FD 后才可安全删除。
    for file_descriptor in "${VM_INPUT_FD[@]:-}" "${NOISE_INPUT_FD[@]:-}"; do
        if [[ $file_descriptor =~ ^[0-9]+$ ]]; then
            exec {file_descriptor}>&- || true
        fi
    done

    for path in "${VM_API_SOCKET[@]:-}" "${VM_STDIN_FIFO[@]:-}" \
                "${NOISE_API_SOCKET[@]:-}" "${NOISE_STDIN_FIFO[@]:-}"; do
        [[ -n $path ]] && rm -f -- "$path"
    done

    # 只删除本轮 RUN_DIR/work 下由脚本复制出的 rootfs，绝不删除 base ext4。
    # 调试启动问题时可设置 KEEP_DISKS=1 保留这些副本。
    if [[ $KEEP_DISKS == 0 && -n $RUN_DIR ]]; then
        for path in "${VM_ROOTFS[@]:-}" "${NOISE_ROOTFS[@]:-}"; do
            [[ -n $path && $path == "$RUN_DIR/work/"* ]] && rm -f -- "$path"
        done
        rmdir "$RUN_DIR/work" 2>/dev/null || true
    fi

    exit "$original_exit_code"
}

# 轮询串口日志，直到出现指定标记。
# 同时检查 Firecracker PID；若进程提前退出，就立即失败，不必等完整超时。
wait_for_console_marker() {
    local console_log=$1 expected_marker=$2 firecracker_pid=$3 timeout_seconds=$4
    local deadline=$((SECONDS + timeout_seconds))

    while ((SECONDS <= deadline)); do
        grep -aFq "$expected_marker" "$console_log" 2>/dev/null && return 0
        kill -0 "$firecracker_pid" 2>/dev/null || return 1
        sleep 0.02
    done
    return 1
}

# 将本文件内嵌的 guest init 写入“临时 rootfs 副本”。
# debugfs 可以离线修改 ext4，因此不需要 mount，也不会碰原始 base ext4。
install_guest_init() {
    local rootfs_copy=$1 guest_init_source=$2 debugfs_log=$3

    # 若镜像里恰好已有同名文件，先删除；这里操作的仍然只是临时副本。
    debugfs -w -R 'rm /fc-exp-init.sh' "$rootfs_copy" >>"$debugfs_log" 2>&1 || true
    debugfs -w -R "write $guest_init_source /fc-exp-init.sh" \
        "$rootfs_copy" >>"$debugfs_log" 2>&1
    debugfs -w -R 'set_inode_field /fc-exp-init.sh mode 0100755' \
        "$rootfs_copy" >>"$debugfs_log" 2>&1

    # 写完马上验证执行位；否则 VM 能启动，但内核无法执行 init，错误不直观。
    debugfs -R 'stat /fc-exp-init.sh' "$rootfs_copy" 2>>"$debugfs_log" |
        grep -q 'Mode:.*0755' || die "guest init 注入失败: $rootfs_copy"
}

# 为一台 microVM 生成 Firecracker JSON 配置。
# 实验固定 vcpu_count=1：N=5 表示五台 1-vCPU 沙箱共享一个宿主机 CPU，
# 不是在一台 VM 内创建五个 vCPU。
write_firecracker_config() {
    local config_file=$1 rootfs_copy=$2 kernel_boot_args=$3

    # 下面直接把路径放入 JSON 字符串，因此显式拒绝未转义的双引号。
    [[ $KERNEL_IMAGE$rootfs_copy$kernel_boot_args != *'"'* ]] || \
        die "kernel、rootfs 或 boot_args 中不能包含双引号"

    cat >"$config_file" <<EOF
{
  "boot-source": {
    "kernel_image_path": "$(readlink -f "$KERNEL_IMAGE")",
    "boot_args": "$kernel_boot_args"
  },
  "drives": [{
    "drive_id": "rootfs",
    "path_on_host": "$(readlink -f "$rootfs_copy")",
    "is_root_device": true,
    "is_read_only": false
  }],
  "machine-config": {"vcpu_count": 1, "mem_size_mib": $MEM_MIB}
}
EOF
}

# 再次绑定并逐线程核验一台 Firecracker 的全部宿主机线程。
#
# Firecracker 启动命令本身已经由 taskset 绑定 TARGET_CPU，新线程会继承该
# affinity。等 guest 报 READY 后，再用 taskset -a 覆盖一次并遍历 /proc 校验，
# 是为了明确保证：vCPU、API、VMM 等“该沙箱的全部线程”都在实验核上。
pin_and_verify_all_firecracker_threads() {
    local vm_index=$1
    local firecracker_pid=${VM_PROCESS_PID[$vm_index]}
    local task_directory thread_id allowed_cpus thread_name

    taskset -a -pc "$TARGET_CPU" "$firecracker_pid" >/dev/null

    # 避免继承到实时调度策略或特殊 nice 值，使 N=1/N=5 的调度条件一致。
    chrt -a -o -p 0 "$firecracker_pid" >/dev/null

    for task_directory in /proc/"$firecracker_pid"/task/*; do
        thread_id=${task_directory##*/}
        renice -n 0 -p "$thread_id" >/dev/null
        allowed_cpus=$(awk '/^Cpus_allowed_list:/{print $2}' "$task_directory/status")
        [[ $allowed_cpus == "$TARGET_CPU" ]] || \
            die "线程绑核校验失败: tid=$thread_id 实际CPU=$allowed_cpus 预期CPU=$TARGET_CPU"

        thread_name=$(<"$task_directory/comm")
        printf '%s,%s,%s,%s,%s\n' \
            "$vm_index" "${CASE_WORKLOADS[$vm_index]}" "$firecracker_pid" \
            "$thread_id" "$thread_name" >>"$RUN_DIR/threads.csv"
    done
}

# 在 target Firecracker 的线程列表中找到唯一被观测对象“fc_vcpu 0”。
# 后续 perf 过滤器和 AWK 分析都只使用这个 TID，不把 API/VMM 线程误算进去。
find_target_vcpu_tid() {
    local firecracker_pid=$1 task_directory
    local deadline=$((SECONDS + READY_TIMEOUT))

    while ((SECONDS <= deadline)); do
        for task_directory in /proc/"$firecracker_pid"/task/*; do
            if [[ -r $task_directory/comm && $(<"$task_directory/comm") == 'fc_vcpu 0' ]]; then
                printf '%s\n' "${task_directory##*/}"
                return 0
            fi
        done
        sleep 0.02
    done
    return 1
}

# 读取一个宿主机线程当前的调度策略和实时优先级。
# 返回值通过全局变量 CURRENT_SCHED_POLICY / CURRENT_SCHED_PRIORITY 传出，
# 避免调用者依赖 chrt 输出行号。
read_thread_scheduler_state() {
    local thread_id=$1 scheduler_text

    scheduler_text=$(chrt -p "$thread_id") || \
        die "无法读取线程调度策略: tid=$thread_id"

    CURRENT_SCHED_POLICY=$(sed -n \
        's/.*current scheduling policy: //p' <<<"$scheduler_text" | tail -1)
    CURRENT_SCHED_PRIORITY=$(sed -n \
        's/.*current scheduling priority: //p' <<<"$scheduler_text" | tail -1)

    [[ -n $CURRENT_SCHED_POLICY && $CURRENT_SCHED_PRIORITY =~ ^[0-9]+$ ]] || \
        die "无法解析线程调度策略: tid=$thread_id"
}

# 配置并核验本轮所有 Firecracker 线程的调度策略。
#
# n1 / n5：
#   所有线程都必须是 SCHED_OTHER，保持原有 CFS 实验不变。
#
# n5_fifo：
#   只有 target 的 fc_vcpu 0 使用 SCHED_FIFO；target 的 main/API 线程以及
#   四台 background VM 的所有线程仍必须是 SCHED_OTHER。
#
# 这里按 TID 调用 chrt，刻意不带 -a。chrt -a 会把同一 Firecracker 进程
# 内的 main、API 等线程也改成 FIFO，既改变实验问题，也可能造成不必要的饥饿。
configure_and_verify_thread_schedulers() {
    local vm_index firecracker_pid task_directory thread_id thread_name
    local expected_policy expected_priority allowed_cpus

    HOST_SCHED_RT_PERIOD_US=$(</proc/sys/kernel/sched_rt_period_us)
    HOST_SCHED_RT_RUNTIME_US=$(</proc/sys/kernel/sched_rt_runtime_us)

    if [[ $EXPERIMENT_MODE == n5_fifo ]]; then
        # runtime=0 表示实时线程没有可用运行预算，这种环境下即使 chrt 成功，
        # FIFO 对照也没有实验意义；-1 表示不限制，其余正数表示有限 RT 预算。
        [[ $HOST_SCHED_RT_RUNTIME_US != 0 ]] || \
            die "宿主机 sched_rt_runtime_us=0，SCHED_FIFO 没有可用运行预算"

        chrt -f -p "$TARGET_FIFO_PRIORITY" "$TARGET_VCPU_TID" || \
            die "无法把 target vCPU 设置为 SCHED_FIFO: tid=$TARGET_VCPU_TID"
        TARGET_SCHED_POLICY=SCHED_FIFO
        TARGET_SCHED_PRIORITY=$TARGET_FIFO_PRIORITY
    else
        # launch_vm 已把全部线程恢复成 SCHED_OTHER；这里再次显式设置 target
        # vCPU，保证 scheduling.csv 记录的就是测量窗口开始前的最终状态。
        chrt -o -p 0 "$TARGET_VCPU_TID" || \
            die "无法把 target vCPU 设置为 SCHED_OTHER: tid=$TARGET_VCPU_TID"
        TARGET_SCHED_POLICY=SCHED_OTHER
        TARGET_SCHED_PRIORITY=0
    fi

    printf 'vm_index,workload,pid,tid,comm,policy,rt_priority,cpu_allowed_list\n' \
        >"$RUN_DIR/scheduling.csv"

    for ((vm_index=0; vm_index<${#CASE_WORKLOADS[@]}; vm_index++)); do
        firecracker_pid=${VM_PROCESS_PID[$vm_index]:-}
        [[ $firecracker_pid =~ ^[0-9]+$ ]] || \
            die "缺少 VM[$vm_index] Firecracker PID，无法验证调度策略"

        for task_directory in /proc/"$firecracker_pid"/task/*; do
            [[ -d $task_directory ]] || \
                die "Firecracker 线程在策略核验时消失: pid=$firecracker_pid"

            thread_id=${task_directory##*/}
            thread_name=$(<"$task_directory/comm")
            allowed_cpus=$(awk '/^Cpus_allowed_list:/{print $2}' \
                "$task_directory/status")
            [[ $allowed_cpus == "$TARGET_CPU" ]] || \
                die "策略核验时发现线程绑核错误: tid=$thread_id CPU=$allowed_cpus"

            expected_policy=SCHED_OTHER
            expected_priority=0
            if [[ $EXPERIMENT_MODE == n5_fifo && \
                  $vm_index == 0 && $thread_id == "$TARGET_VCPU_TID" ]]; then
                expected_policy=SCHED_FIFO
                expected_priority=$TARGET_FIFO_PRIORITY
            fi

            read_thread_scheduler_state "$thread_id"
            [[ $CURRENT_SCHED_POLICY == "$expected_policy" && \
               $CURRENT_SCHED_PRIORITY == "$expected_priority" ]] || \
                die "线程调度策略不符合实验设计: tid=$thread_id comm=$thread_name 实际=$CURRENT_SCHED_POLICY/$CURRENT_SCHED_PRIORITY 预期=$expected_policy/$expected_priority"

            printf '%s,%s,%s,%s,%s,%s,%s,%s\n' \
                "$vm_index" "${CASE_WORKLOADS[$vm_index]}" "$firecracker_pid" \
                "$thread_id" "$thread_name" "$CURRENT_SCHED_POLICY" \
                "$CURRENT_SCHED_PRIORITY" "$allowed_cpus" \
                >>"$RUN_DIR/scheduling.csv"
        done
    done

    log "线程策略已核验 target_vcpu=$TARGET_SCHED_POLICY/$TARGET_SCHED_PRIORITY 其余线程=SCHED_OTHER/0"
}

# 启动一台 microVM，并让 guest 停在 READY/GO 屏障处。
# 参数：$1 是 VM 下标；$2 是角色，只能为 target 或 background。
launch_vm() {
    local vm_index=$1 role=$2 workload_name=${CASE_WORKLOADS[$1]}
    local rootfs_copy config_file stdin_fifo console_log api_socket
    local input_fd firecracker_pid kernel_boot_args

    rootfs_copy="$RUN_DIR/work/${vm_index}_${workload_name}.ext4"
    config_file="$RUN_DIR/${vm_index}_${workload_name}.json"
    stdin_fifo="$RUN_DIR/work/${vm_index}.stdin"
    console_log="$RUN_DIR/${vm_index}_${workload_name}.console.log"
    # Unix socket 路径长度有限，因此 API socket 放在较短的 /tmp 路径下。
    api_socket="/tmp/fc-exp-${$}-${vm_index}.sock"

    # 先登记路径。即使后面某一步失败，EXIT trap 也知道要清理哪些文件。
    VM_ROOTFS[$vm_index]=$rootfs_copy
    VM_API_SOCKET[$vm_index]=$api_socket
    VM_STDIN_FIFO[$vm_index]=$stdin_fifo

    # 1. 为本 VM 复制独立 rootfs；base ext4 始终只读，不会被实验污染。
    log "准备 VM[$vm_index] role=$role workload=$workload_name"
    cp --reflink=auto --sparse=always "${ROOTFS_OF[$workload_name]}" "$rootfs_copy"
    install_guest_init "$rootfs_copy" "$RUN_DIR/guest-init.sh" "$RUN_DIR/debugfs.log"

    # 2. 通过 kernel cmdline 把角色和 workload 配置传给内嵌 guest init。
    kernel_boot_args="keep_bootcon console=ttyS0 reboot=k panic=1 pci=off root=/dev/vda rw rootwait"
    kernel_boot_args+=" init=/fc-exp-init.sh fc_role=$role fc_name=$workload_name"
    kernel_boot_args+=" fc_repo=${GUEST_REPO_OF[$workload_name]}"
    kernel_boot_args+=" fc_commit=${COMMIT_OF[$workload_name]}"
    kernel_boot_args+=" fc_replay=${REPLAY_OF[$workload_name]}"
    kernel_boot_args+=" fc_save_replay_log=$SAVE_REPLAY_LOG"
    kernel_boot_args+=" fc_replay_log_mib=$REPLAY_LOG_MIB"
    write_firecracker_config "$config_file" "$rootfs_copy" "$kernel_boot_args"

    # 3. FIFO 是宿主机到 guest 串口的控制通道。用读写方式打开可避免在
    #    Firecracker 启动前阻塞，也避免暂时没有 writer 时读端收到 EOF。
    rm -f -- "$api_socket"
    mkfifo "$stdin_fifo"
    exec {input_fd}<>"$stdin_fifo"

    # 4. 从进程创建的第一刻就绑定 TARGET_CPU，之后创建的全部 FC 线程会
    #    继承这个 affinity。这里没有 Kata、containerd 或额外 runtime。
    taskset -c "$TARGET_CPU" "$FIRECRACKER_BIN" \
        --api-sock "$api_socket" --config-file "$config_file" \
        <&"$input_fd" >"$console_log" 2>&1 &
    firecracker_pid=$!

    VM_PROCESS_PID[$vm_index]=$firecracker_pid
    VM_INPUT_FD[$vm_index]=$input_fd
    VM_CONSOLE_LOG[$vm_index]=$console_log

    # 5. READY 表示 guest 初始化和 git reset 已完成，但 replay 尚未开始。
    if ! wait_for_console_marker "$console_log" \
        "FC_READY role=$role name=$workload_name" "$firecracker_pid" "$READY_TIMEOUT"; then
        tail -80 "$console_log" >&2 || true
        die "VM 未进入 READY 状态: $workload_name"
    fi

    pin_and_verify_all_firecracker_threads "$vm_index"
    log "VM[$vm_index] 已就绪 role=$role workload=$workload_name pid=$firecracker_pid"
}

# 向指定 VM 的串口发送一行控制命令。
send_guest_command() {
    local input_fd=${VM_INPUT_FD[$1]} command=$2
    printf '%s\n' "$command" >&"$input_fd"
}

# 向指定 VM 发送 GO，解除 guest init 的 READY/GO 屏障。
send_guest_go() {
    send_guest_command "$1" GO
}

# 从 target 串口日志的 BEGIN/END 标记之间提取 replay stdout/stderr。
# 串口可能使用 CRLF，因此只移除每行末尾的 CR；其余文本保持原样。
extract_target_replay_log() {
    local console_log=${VM_CONSOLE_LOG[0]}
    local output_log="$RUN_DIR/replay.log"
    local begin_marker="FC_REPLAY_LOG_BEGIN name=$TARGET_WORKLOAD"
    local end_marker="FC_REPLAY_LOG_END name=$TARGET_WORKLOAD"

    awk -v begin_marker="$begin_marker" -v end_marker="$end_marker" '
        {
            line = $0
            sub(/\r$/, "", line)

            if (line == begin_marker) {
                capture = 1
                begin_seen = 1
                next
            }
            if (line == end_marker) {
                if (capture) {
                    end_seen = 1
                    capture = 0
                    exit
                }
                next
            }
            if (capture)
                print line
        }
        END {
            if (!begin_seen || !end_seen)
                exit 1
        }
    ' "$console_log" >"$output_log" || {
        rm -f -- "$output_log"
        die "无法从 target 串口日志提取 replay.log"
    }
}

# ============================= perf 采集与分析 ================================

# 启动 perf kvm，只采 TARGET_CPU，但暂时不启用事件。
#
# perf kvm stat record 会根据宿主机架构自动加入 KVM entry/exit tracepoint，
# 这些事件供后续 perf kvm stat report 统计 VM-exit 原因与处理时间。
#
# 我们另外加入三组事件：
#   1. sched_switch：计算调度次数、主动/被动、时间片、gap、onCPU；
#   2. sched_waking/wakeup：拆分“真正阻塞”和“唤醒后等待 CPU”；
#   3. WFx、KVM block、虚拟定时器及虚拟 IRQ：判断主动调出和唤醒原因。
#
# 因此整个实验仍然只有一个采集进程和一个 perf.data，不需要同时运行第二个
# 普通 perf record。
start_perf_recording() {
    # 使用两个 FIFO 建立双向握手：control 发送命令，ack 确认命令已完成。
    # 宿主机以读写方式打开 FIFO，避免启动先后顺序造成 open 阻塞；FD 会继承
    # 给 perf，具体编号通过 --control fd:控制FD,确认FD 传入。
    PERF_CONTROL_FIFO="$RUN_DIR/work/perf-control.fifo"
    PERF_ACK_FIFO="$RUN_DIR/work/perf-control-ack.fifo"
    mkfifo "$PERF_CONTROL_FIFO" "$PERF_ACK_FIFO"
    exec {PERF_CONTROL_FD}<>"$PERF_CONTROL_FIFO"
    exec {PERF_ACK_FD}<>"$PERF_ACK_FIFO"

    # taskset 只把 perf kvm 的用户态进程放到 HOUSEKEEPING_CPU；
    # -a -C TARGET_CPU 才表示事件来自实验核，避免采集程序本身争抢实验核。
    #
    # 这里显式传 --host --guest，不能再传 --no-guest。
    #
    # 需要特别区分两件事：我们逻辑上分析的确实是“宿主机侧的
    # KVM tracepoint”；但 perf 的 --no-guest 不是一个文本输出开关，它会给
    # 每个事件设置 perf_event_attr.exclude_guest=1。用户的 ARM64/openEuler
    # 机器已实测证明，这会把 kvm_entry、kvm_exit 和 kvm_wfx_arm64
    # 全部过滤掉，只剩 sched_switch。
    #
    # perf kvm 默认已保留 guest 上下文；这里显式同时保留
    # host/guest，避免不同 perf 版本的默认值差异。
    # 我们仍然只采集明确列出的 KVM/sched tracepoint，不会因此采集
    # guest 指令流或 guest 符号。
    #
    # --delay=-1 让所有事件以 disabled 状态创建。perf 此时已经完成参数解析、
    # tracepoint 打开和缓冲区初始化，但不会记录 target 的 READY 等待事件。
    # -o 必须放在 stat 子命令之前，它是 perf kvm 的公共输出文件参数。
    #
    # 这里故意不指定 --clockid：部分服务器内核会拒绝 CLOCK_REALTIME，并报
    # "wrong clockid (0)"。采集窗口已经由 enable/disable ack 严格控制，分析
    # 阶段只需使用 perf.data 内部一致的默认时钟，不必把事件时间戳与 date 对齐。
    taskset -c "$HOUSEKEEPING_CPU" perf kvm --host --guest \
        -o "$RUN_DIR/perf.data" stat record \
        -a -C "$TARGET_CPU" \
        --delay=-1 --control "fd:${PERF_CONTROL_FD},${PERF_ACK_FD}" \
        -e sched:sched_switch \
            --filter "prev_pid == $TARGET_VCPU_TID || next_pid == $TARGET_VCPU_TID" \
        -e sched:sched_waking \
            --filter "pid == $TARGET_VCPU_TID" \
        -e sched:sched_wakeup \
            --filter "pid == $TARGET_VCPU_TID" \
        -e kvm:kvm_wfx_arm64 --filter "common_pid == $TARGET_VCPU_TID" \
        -e kvm:kvm_vcpu_wakeup --filter "common_pid == $TARGET_VCPU_TID" \
        -e kvm:kvm_timer_hrtimer_expire \
        -e kvm:kvm_timer_emulate \
        -e kvm:kvm_timer_update_irq \
        -e kvm:kvm_irq_line \
        -e kvm:vgic_update_irq_pending \
        >"$RUN_DIR/perf-kvm-record.log" 2>&1 &
    PERF_RECORD_PID=$!

    # perf kvm 如果未编译 KVM stat 支持，或某个 tracepoint/filter 不兼容，
    # 通常会立即退出；在 target 开始 replay 前检查，避免白跑一轮实验。
    sleep 1
    if ! kill -0 "$PERF_RECORD_PID" 2>/dev/null; then
        cat "$RUN_DIR/perf-kvm-record.log" >&2
        die "perf kvm stat record 启动失败"
    fi

    # ping/ack 不改变事件状态，只证明 perf 已经进入控制循环。此时事件仍然
    # disabled，因此上面的 1 秒启动检查不会进入 perf.data。
    if ! send_perf_control_command ping; then
        cat "$RUN_DIR/perf-kvm-record.log" >&2 || true
        die "perf 控制通道未返回 ack；请确认当前 perf 支持 --control"
    fi
    log "perf kvm 已就绪（事件尚未启用）target_vcpu_tid=$TARGET_VCPU_TID cpu=$TARGET_CPU"
}

# 真正打开采集窗口。只有收到 enable 的 ack 后，调用者才可以向 guest 发送
# GO；这样既排除启动阶段，也不会因 perf 初始化较慢而漏采 workload 开头。
enable_perf_events() {
    if ! send_perf_control_command enable; then
        cat "$RUN_DIR/perf-kvm-record.log" >&2 || true
        die "perf enable 未收到 ack，target 尚未开始执行"
    fi
    PERF_EVENTS_ENABLED=1
}

# 关闭采集窗口。等待 disable ack 后，perf.data 中不会再新增调度/KVM 样本；
# perf 进程仍保留到 stop_perf_recording，以便正常刷新缓冲区和文件头。
disable_perf_events() {
    local disable_start_ns disable_end_ns

    [[ ${PERF_EVENTS_ENABLED:-0} == 1 ]] || return 0

    disable_start_ns=$(date +%s%N)
    if ! send_perf_control_command disable; then
        PERF_EVENTS_ENABLED=0
        cat "$RUN_DIR/perf-kvm-record.log" >&2 || true
        die "perf disable 未收到 ack"
    fi
    disable_end_ns=$(date +%s%N)
    PERF_DISABLE_ACK_MS=$(( (disable_end_ns-disable_start_ns)/1000000 ))
    PERF_EVENTS_ENABLED=0
    log "perf 事件已禁用 disable_ack=${PERF_DISABLE_ACK_MS}ms"
}

# 使用 perf kvm 自带的报告器生成 target microVM 的 VM-exit 统计。
#
# perf kvm stat report 的 --pid 按进程 ID（TGID）过滤，因此这里传
# target Firecracker PID，不传 fc_vcpu 线程 TID。PERF_SAMPLE_TID 样本
# 同时保存 TGID/TID；下面的 AWK 逐事件归因仍然使用 vCPU TID。
# 每台实验 microVM 固定只有一个 vCPU，因此不再额外传 --vcpu=0。
# 报告包含各 VM-exit 类型的次数、占比、总耗时、最小/最大/平均处理时间。
generate_kvm_stat_report() {
    local target_firecracker_pid=${VM_PROCESS_PID[0]}

    # 当前 openEuler perf 6.6 会把正常的人类可读报告写到 stderr，而不是
    # stdout。旧版本分别重定向两个流，导致 kvm-stat-report.txt 为空、
    # 正常报告反而落入 kvm-stat-report.err，随后又被误读成 WFx=0。
    #
    # 这里将两个流合并到正式报告文件。命令失败时同一个文件也保留诊断信息。
    if ! PERF_PAGER=cat taskset -c "$HOUSEKEEPING_CPU" \
        perf kvm --host --guest -i "$RUN_DIR/perf.data" \
            stat report --event=vmexit \
            --pid="$target_firecracker_pid" \
            >"$RUN_DIR/kvm-stat-report.txt" 2>&1; then
        cat "$RUN_DIR/kvm-stat-report.txt" >&2 || true
        die "perf kvm stat report 生成失败"
    fi

    # perf kvm 在“没有匹配样本”时也可能返回 0，因此不能只检查退出码。
    # target replay 正常执行时必然存在 VM-exit；报告必须包含非零总样本数。
    if ! grep -Eq '^Total Samples:[[:space:]]*[1-9][0-9,]*,' \
        "$RUN_DIR/kvm-stat-report.txt"; then
        cat "$RUN_DIR/kvm-stat-report.txt" >&2 || true
        die "perf kvm stat report 未产生 target VM-exit 样本"
    fi

    # 保留旧文件名，便于既有排查命令继续工作；成功时该文件应为空。
    : >"$RUN_DIR/kvm-stat-report.err"
}

# 将 perf.data 转为文本，然后同时完成两类后处理：
#   1. perf kvm stat report：官方 VM-exit 次数与处理时间统计；
#   2. AWK：我们关心的调度次数、主动/被动、时间片、gap、onCPU 与 WFI/WFE。
analyze_perf_data() {
    local sched_line_count kvm_entry_count kvm_exit_count kvm_wfx_count
    local sched_waking_count sched_wakeup_count kvm_vcpu_wakeup_count
    local kvm_timer_expire_count kvm_timer_emulate_count
    local kvm_timer_update_count kvm_irq_line_count vgic_update_count
    local kvm_report_wfx_count wakeup_events_recorded
    local summary_columns summary_unparsed summary_missing_wakeup
    local summary_missing_waking summary_invalid_order
    local summary_parsed_waking summary_parsed_wakeup
    local summary_unmatched_entry summary_unmatched_exit
    local summary_negative_guest summary_negative_host

    # 保存实际写入 perf.data 的事件属性，便于复核采集参数。
    # 若 KVM tracepoint 仍然带 exclude_guest=1，就在产生任何报告前
    # 立即报错，避免再次把“没采到”误认为“事件为 0”。
    if ! PERF_PAGER=cat perf evlist -v -i "$RUN_DIR/perf.data" \
        >"$RUN_DIR/perf-evlist.txt" 2>"$RUN_DIR/perf-evlist.err"; then
        cat "$RUN_DIR/perf-evlist.err" >&2 || true
        die "无法读取 perf.data 事件属性"
    fi
    if grep -Eq '^kvm:.*exclude_guest: 1' "$RUN_DIR/perf-evlist.txt"; then
        die "KVM tracepoint 仍带 exclude_guest=1，当前 perf 参数会漏采 KVM 事件"
    fi

    # v14 旧数据没有 sched_waking/wakeup，仍允许用 v15 补算 guest 时间；
    # 只有真正由 v15 采集的数据才输出完整的阻塞/排队及唤醒原因。
    wakeup_events_recorded=0
    if grep -q '^sched:sched_waking:' "$RUN_DIR/perf-evlist.txt" && \
       grep -q '^sched:sched_wakeup:' "$RUN_DIR/perf-evlist.txt"; then
        wakeup_events_recorded=1
    fi

    generate_kvm_stat_report

    # 这台 ARM64/openEuler 机器会把 vCPU 正在 guest 上下文中产生的样本标为
    # guest code。普通 `perf script` 会隐藏这些样本，表现为：只能看到 target
    # 调入，既看不到 target 调出，也看不到 KVM entry/exit/WFX。
    #
    # 不能使用 --guest-code。该选项假设 guest 代码与 VMM 用户态进程使用
    # 相同地址映射，主要面向 KVM selftest；完整 Firecracker Linux guest
    # 并不满足这个假设。N=5 中它需要为五台 VM 克隆 VMM 映射，实测会偶发
    # “problem processing 9 event / type 68”并中止文本导出。
    #
    # --guestvmlinux 使用本轮启动 VM 的 kernel 来启用正常 guest 样本处理。
    # 我们只导出 tracepoint 字段、不解析 guest 符号，因此官方 ARM64 boot
    # Image 也可使用。实机验证：N=5 的 entry/exit 均为 173299，正好等于
    # perf kvm 全 VM 报告；target WFx 也同为 3161。
    #
    # -F 只作用于 tracepoint，避免 perf 6.6 对 dummy 等非 tracepoint 事件输出
    # “trace field not valid”警告；所列字段正好也是下面 AWK 解析所需字段。
    if ! perf script --guestvmlinux="$KERNEL_IMAGE" \
        -i "$RUN_DIR/perf.data" --ns \
        -F trace:comm,pid,tid,cpu,time,event,trace \
        >"$RUN_DIR/perf.txt" 2>"$RUN_DIR/perf-script.log"; then
        cat "$RUN_DIR/perf-script.log" >&2 || true
        die "perf script --guestvmlinux 解码失败"
    fi

    # 在进入统计前先做一次最小完整性检查。不再允许出现
    # “perf.data 很大，但 perf.txt 漏了 KVM 事件，最终静默输出全 0”。
    sched_line_count=$(grep -c 'sched:sched_switch:' "$RUN_DIR/perf.txt" || true)
    kvm_entry_count=$(grep -Ec 'kvm:kvm_entry(_v2)?:' "$RUN_DIR/perf.txt" || true)
    kvm_exit_count=$(grep -Ec 'kvm:kvm_exit(_v2)?:' "$RUN_DIR/perf.txt" || true)
    kvm_wfx_count=$(grep -c 'kvm:kvm_wfx_arm64:' "$RUN_DIR/perf.txt" || true)
    sched_waking_count=$(grep -c 'sched:sched_waking:' "$RUN_DIR/perf.txt" || true)
    sched_wakeup_count=$(grep -c 'sched:sched_wakeup:' "$RUN_DIR/perf.txt" || true)
    kvm_vcpu_wakeup_count=$(grep -c 'kvm:kvm_vcpu_wakeup:' "$RUN_DIR/perf.txt" || true)
    kvm_timer_expire_count=$(grep -c 'kvm:kvm_timer_hrtimer_expire:' "$RUN_DIR/perf.txt" || true)
    kvm_timer_emulate_count=$(grep -c 'kvm:kvm_timer_emulate:' "$RUN_DIR/perf.txt" || true)
    kvm_timer_update_count=$(grep -c 'kvm:kvm_timer_update_irq:' "$RUN_DIR/perf.txt" || true)
    kvm_irq_line_count=$(grep -c 'kvm:kvm_irq_line:' "$RUN_DIR/perf.txt" || true)
    vgic_update_count=$(grep -c 'kvm:vgic_update_irq_pending:' "$RUN_DIR/perf.txt" || true)
    # 不同 perf 版本可能打印 WFx/WFX，并可能给大数字加千位逗号。
    kvm_report_wfx_count=$(awk '
        toupper($1)=="WFX" {
            count=$2
            gsub(/,/,"",count)
            if (count ~ /^[0-9]+$/) { print count; exit }
        }
    ' "$RUN_DIR/kvm-stat-report.txt")
    kvm_report_wfx_count=${kvm_report_wfx_count:-0}

    {
        printf 'sched_switch=%s\n' "$sched_line_count"
        printf 'kvm_entry=%s\n' "$kvm_entry_count"
        printf 'kvm_exit=%s\n' "$kvm_exit_count"
        printf 'kvm_wfx_arm64=%s\n' "$kvm_wfx_count"
        printf 'kvm_report_target_wfx=%s\n' "$kvm_report_wfx_count"
        printf 'sched_waking=%s\n' "$sched_waking_count"
        printf 'sched_wakeup=%s\n' "$sched_wakeup_count"
        printf 'kvm_vcpu_wakeup=%s\n' "$kvm_vcpu_wakeup_count"
        printf 'kvm_timer_hrtimer_expire=%s\n' "$kvm_timer_expire_count"
        printf 'kvm_timer_emulate=%s\n' "$kvm_timer_emulate_count"
        printf 'kvm_timer_update_irq=%s\n' "$kvm_timer_update_count"
        printf 'kvm_irq_line=%s\n' "$kvm_irq_line_count"
        printf 'vgic_update_irq_pending=%s\n' "$vgic_update_count"
        printf 'wakeup_events_recorded=%s\n' "$wakeup_events_recorded"
    } >"$RUN_DIR/perf-event-counts.txt"

    (( sched_line_count > 0 )) || \
        die "perf.txt 中没有 sched_switch，无法统计调度指标"
    (( kvm_entry_count > 0 && kvm_exit_count > 0 )) || \
        die "perf.txt 中没有完整 KVM entry/exit，无法可靠归因主动调出"
    if (( kvm_wfx_count != kvm_report_wfx_count )); then
        die "WFx 数量不一致：perf.txt=$kvm_wfx_count，KVM报告=$kvm_report_wfx_count"
    fi

    awk -v target_tid="$TARGET_VCPU_TID" \
        -v target_tgid="${VM_PROCESS_PID[0]}" \
        -v wall_start="$WINDOW_START_TIME" -v wall_end="$WINDOW_END_TIME" \
        -v experiment_mode="$EXPERIMENT_MODE" -v target="$TARGET_WORKLOAD" \
        -v round_id="$ROUND_ID" -v summary_file="$RUN_DIR/summary.csv" \
        -v event_file="$RUN_DIR/switch_out_events.csv" \
        -v cause_summary_file="$RUN_DIR/wakeup_cause_summary.csv" \
        -v wakeup_events_recorded="$wakeup_events_recorded" \
        -v cause_window_us="$WAKE_CAUSE_WINDOW_US" '
        # 对可能含逗号或双引号的 comm/KVM 上下文做标准 CSV 转义。
        function csv_quote(value, escaped) {
            escaped=value
            gsub(/"/,"\"\"",escaped)
            return "\"" escaped "\""
        }

        # perf script 时间字段的形态为“秒.纳秒:”。返回数值秒。
        function event_time(line, matched_time) {
            if (!match(line,/[0-9]+\.[0-9]+:/)) return -1
            matched_time=substr(line,RSTART,RLENGTH-1)
            return matched_time+0
        }

        # perf kvm stat record 自动加入的 entry/exit 会包含实验核上全部 VM。
        # perf script 前缀包含“进程PID/线程TID [CPU] 时间”，这里取出样本 TID，
        # 以便 KVM 归因只使用 target 的 fc_vcpu 0，而不混入四台 background。
        function sample_tid(line, prefix, id_pair) {
            if (!match(line,/[0-9]+\.[0-9]+:/)) return -1
            prefix=substr(line,1,RSTART-1)
            sub(/[[:space:]]+\[[0-9]+\][[:space:]]*$/, "", prefix)

            if (match(prefix,/[0-9]+\/[0-9]+[[:space:]]*$/)) {
                id_pair=substr(prefix,RSTART,RLENGTH)
                sub(/^.*\//,"",id_pair)
                gsub(/[[:space:]]/,"",id_pair)
                return id_pair+0
            }
            if (match(prefix,/[0-9]+[[:space:]]*$/)) {
                id_pair=substr(prefix,RSTART,RLENGTH)
                gsub(/[[:space:]]/,"",id_pair)
                return id_pair+0
            }
            return -1
        }

        # perf script 前缀中的第一个 ID 是 TGID。KVM 定时器/IRQ 事件可能由
        # Firecracker 的非 vCPU 线程触发，因此同时保留 TGID 和 TID，才能判断
        # 唤醒者是否属于 target Firecracker。
        function sample_tgid(line, prefix, id_pair) {
            if (!match(line,/[0-9]+\.[0-9]+:/)) return -1
            prefix=substr(line,1,RSTART-1)
            sub(/[[:space:]]+\[[0-9]+\][[:space:]]*$/, "", prefix)

            if (match(prefix,/[0-9]+\/[0-9]+[[:space:]]*$/)) {
                id_pair=substr(prefix,RSTART,RLENGTH)
                sub(/\/.*$/,"",id_pair)
                gsub(/[[:space:]]/,"",id_pair)
                return id_pair+0
            }
            if (match(prefix,/[0-9]+[[:space:]]*$/)) {
                id_pair=substr(prefix,RSTART,RLENGTH)
                gsub(/[[:space:]]/,"",id_pair)
                return id_pair+0
            }
            return -1
        }

        # 取样本发生时 current 线程的 comm。sched_waking 的 comm/pid 字段是
        # “被唤醒者”，而这个前缀 comm/TID 才是“执行唤醒操作的人”。
        function sample_comm(line, prefix) {
            if (!match(line,/[0-9]+\.[0-9]+:/)) return ""
            prefix=substr(line,1,RSTART-1)
            sub(/[[:space:]]+\[[0-9]+\][[:space:]]*$/, "", prefix)
            sub(/[[:space:]]+[0-9]+\/[0-9]+[[:space:]]*$/, "", prefix)
            sub(/[[:space:]]+[0-9]+[[:space:]]*$/, "", prefix)
            sub(/^[[:space:]]+/,"",prefix)
            sub(/[[:space:]]+$/,"",prefix)
            return prefix
        }

        # 判断某个 KVM 原因事件是否足够接近本次 sched_waking，且发生在同一个
        # current 线程上下文中。cause_window_us 只用于证据配对，不改变调度计数。
        function cause_is_recent(cause_time, cause_tid, waking_time, waker_tid,
                                 delta_seconds) {
            if (cause_time=="") return 0
            if (cause_tid != waker_tid) return 0
            delta_seconds=waking_time-cause_time
            return delta_seconds >= 0 && \
                   delta_seconds <= (cause_window_us+0)/1000000
        }

        # 某些 KVM 唤醒路径先把 vCPU 变为 TASK_RUNNING，随后才记录
        # vgic_update_irq_pending。例如服务器实测顺序为：
        #
        #   sched_waking -> sched_wakeup -> IRQ 64 level=1 -> sched_switch-in
        #
        # 此函数只检查“已经发生唤醒、尚未重新调入”的当前 gap：
        #   1. 原因事件必须与 sched_waking 使用同一个 current TID；
        #   2. 必须位于唤醒后的 cause_window_us 内；
        #   3. waiting_gap_row 在 target switch-in 后会立即清零，因此不会把
        #      下一次运行期间的普通 IRQ 错配给本次唤醒。
        #
        # 定时器原因仍高于通用 IRQ。只有原结果为 other 时，通用 IRQ 才会
        # 回填；后置定时器则可以覆盖先前的通用 IRQ。
        function attach_post_wake_cause(row_index, cause_time, cause_tid,
                                        cause_kind, cause_detail,
                                        wake_anchor, delta_seconds,
                                        previous_cause) {
            if (row_index <= 0) return
            if (row_kind[row_index] != "voluntary") return
            if (row_waker_tid[row_index] == "") return
            if (cause_tid != row_waker_tid[row_index]) return

            wake_anchor=(row_waking_time[row_index] != "" ? \
                row_waking_time[row_index] : row_wakeup_time[row_index])
            if (wake_anchor == "") return

            delta_seconds=cause_time-wake_anchor
            if (delta_seconds < 0 || \
                delta_seconds > (cause_window_us+0)/1000000) return

            previous_cause=row_wake_cause[row_index]

            if (cause_kind == "kvm_timer") {
                if (previous_cause != "kvm_timer") {
                    if (previous_cause == "" || previous_cause == "other")
                        row_post_wake_reclassified[row_index]=1
                    row_wake_cause[row_index]="kvm_timer"
                    row_wake_evidence[row_index]=cause_detail
                }
            } else if (cause_kind == "virtual_irq" && \
                       (previous_cause == "" || previous_cause == "other")) {
                row_post_wake_reclassified[row_index]=1
                row_wake_cause[row_index]="virtual_irq"
                row_wake_evidence[row_index]=cause_detail
            }
        }

        # 从 sched_switch trace 文本中读取 prev_pid、prev_state、next_pid 等字段。
        function trace_field(line, key, value) {
            value=line
            sub("^.*" key "=","",value)
            sub(/[[:space:]].*$/,"",value)
            return value
        }

        # sched_waking/sched_wakeup 在不同 perf 版本上的正文格式不一致：
        #
        #   1) comm=fc_vcpu 0 pid=383277 prio=120 target_cpu=102
        #   2) fc_vcpu 0:383277 [120] CPU:102
        #
        # 当前 openEuler perf 对 sched_waking 使用第 1 种，对 sched_wakeup
        # 却使用第 2 种。如果只查找 pid=，会把已经完整采集到的 wakeup 全部
        # 错报成缺失。成功时返回被唤醒线程 PID，无法识别时返回 -1。
        function parse_sched_wakeup_pid(line, body, value) {
            body=line
            sub(/^.*sched:sched_(waking|wakeup):[[:space:]]*/,"",body)

            # 字段名格式。先处理正文中间的“ pid=”，再兼容正文以 pid= 开头。
            value=body
            if (sub(/^.*[[:space:]]pid=/,"",value) || \
                sub(/^pid=/,"",value)) {
                sub(/[[:space:]].*$/,"",value)
                if (value ~ /^[0-9]+$/) return value+0
            }

            # 紧凑格式。comm 可能含空格甚至冒号，所以先从 [prio] 处截断，
            # 再取剩余文本最后一个冒号后的十进制 PID。
            if (body ~ /:[0-9]+[[:space:]]+\[[^]]+\]/) {
                value=body
                sub(/[[:space:]]+\[[^]]+\].*$/,"",value)
                sub(/^.*:/,"",value)
                if (value ~ /^[0-9]+$/) return value+0
            }

            return -1
        }

        # 保存本次唤醒的实际执行者，并把紧邻该唤醒、且发生在同一 current
        # 线程中的 KVM 事件作为原因证据。通常从 sched_waking 调用；若某条
        # 路径只有 sched_wakeup，则允许用 sched_wakeup 的同一前缀上下文
        # 回填。两种 tracepoint 都在唤醒者的调度路径中执行。
        function attach_waker_and_cause(row_index, wake_time, line,
                                        waker_tid, waker_tgid, waker_name) {
            waker_tid=sample_tid(line)
            waker_tgid=sample_tgid(line)
            waker_name=sample_comm(line)

            row_waker_tid[row_index]=waker_tid
            row_waker_tgid[row_index]=waker_tgid
            row_waker_comm[row_index]=waker_name

            # 定时器证据优先于通用 VGIC 证据：同一次 timer IRQ 注入通常会
            # 依次产生 timer_update 和 vgic_update。
            if (cause_is_recent(last_timer_cause_time[waker_tid], \
                                waker_tid, \
                                wake_time,waker_tid)) {
                row_wake_cause[row_index]="kvm_timer"
                row_wake_evidence[row_index]= \
                    last_timer_cause_detail[waker_tid]
            } else if (cause_is_recent(last_irq_cause_time[waker_tid], \
                                       waker_tid, \
                                       wake_time,waker_tid)) {
                row_wake_cause[row_index]="virtual_irq"
                row_wake_evidence[row_index]= \
                    last_irq_cause_detail[waker_tid]
            } else {
                row_wake_cause[row_index]="other"
                row_wake_evidence[row_index]=""
            }
        }

        # sched_switch 在不同 perf/内核组合上有两种常见文本格式：
        #
        #   1) prev_comm=foo prev_pid=1 ... prev_state=S ==> next_comm=bar next_pid=2 ...
        #   2) foo:1 [120] S ==> bar:2 [120]
        #
        # 用户机器实际输出第 2 种。旧解析器只认第 1 种，所以把
        # prev_pid/next_pid 都读成 0，最终才会出现“采集成功但统计全为 0”。
        # 函数成功时把结果写入 parsed_* 全局变量，失败返回 0。
        function parse_sched_switch(line, left_part, right_part, value) {
            parsed_previous_pid=-1
            parsed_next_pid=-1
            parsed_previous_state=""
            parsed_next_comm=""

            # 字段名格式。
            if (line ~ /(^|[[:space:]])prev_pid=/ && \
                line ~ /(^|[[:space:]])next_pid=/) {
                parsed_previous_pid=trace_field(line,"prev_pid")+0
                parsed_next_pid=trace_field(line,"next_pid")+0
                parsed_previous_state=trace_field(line,"prev_state")
                parsed_next_comm=line
                sub(/^.*==>[[:space:]]*next_comm=/,"",parsed_next_comm)
                sub(/[[:space:]]+next_pid=.*/,"",parsed_next_comm)
                return 1
            }

            # 紧凑格式：先以 ==> 分成 prev 与 next 两半。
            if (!index(line,"==>")) return 0
            left_part=line
            sub(/[[:space:]]*==>.*$/,"",left_part)
            right_part=line
            sub(/^.*==>[[:space:]]*/,"",right_part)

            # comm 中可以有空格（例如“fc_vcpu 0”），所以从最后一个
            # 冒号后取 PID，再取 [prio] 后的 prev_state。
            value=left_part
            sub(/^.*:/,"",value)
            sub(/[[:space:]].*$/,"",value)
            if (value !~ /^[0-9]+$/) return 0
            parsed_previous_pid=value+0

            value=right_part
            sub(/^.*:/,"",value)
            sub(/[[:space:]].*$/,"",value)
            if (value !~ /^[0-9]+$/) return 0
            parsed_next_pid=value+0

            parsed_previous_state=left_part
            sub(/^.*\][[:space:]]*/,"",parsed_previous_state)
            if (parsed_previous_state=="") return 0

            parsed_next_comm=right_part
            sub(/:[0-9]+[[:space:]]+\[[^]]+\][[:space:]]*$/,"",parsed_next_comm)
            if (parsed_next_comm==right_part) return 0
            return 1
        }

        # 原地快速排序。这里自己实现十几行排序，是为了兼容系统自带的
        # mawk/gawk，不强制要求 GNU awk 的 asort 扩展。
        function quicksort(values, left, right, i, j, pivot, temporary) {
            if (left >= right) return
            i=left
            j=right
            pivot=values[int((left+right)/2)]
            while (i <= j) {
                while (values[i] < pivot) i++
                while (values[j] > pivot) j--
                if (i <= j) {
                    temporary=values[i]
                    values[i]=values[j]
                    values[j]=temporary
                    i++
                    j--
                }
            }
            if (left < j) quicksort(values,left,j)
            if (i < right) quicksort(values,i,right)
        }

        # 与旧实验保持一致，P50/P99 使用线性插值：
        # 在排好序的数组上定位 (n-1)*p，再对相邻两项插值。
        function percentile(sorted_values, value_count, fraction,
                            zero_based_position, lower_index, upper_index, weight) {
            if (value_count == 0) return ""
            zero_based_position=(value_count-1)*fraction
            lower_index=int(zero_based_position)+1
            upper_index=(lower_index < value_count) ? lower_index+1 : lower_index
            weight=zero_based_position-int(zero_based_position)
            return sorted_values[lower_index]*(1-weight) + \
                   sorted_values[upper_index]*weight
        }

        {
            timestamp=event_time($0)
            if (timestamp < 0) next

            # perf.data 本身只在 enable ack 到 disable 命令之间记录样本，因此
            # 不再用 date 的 CLOCK_REALTIME 时间戳过滤。perf 默认事件时钟与
            # date 的时间原点不同，混用会错误地过滤掉全部事件。
            if (first_event_time=="" || timestamp < first_event_time) \
                first_event_time=timestamp
            if (last_event_time=="" || timestamp > last_event_time) \
                last_event_time=timestamp

            # 下列 KVM 事件用于给后续 sched_waking 提供“直接原因证据”。
            # N=5 时五台 VM 的事件会交错，因此必须按 current TID 分开保存
            # “最近一次”事件；若只保存一个全局值，background 事件会覆盖
            # target 的证据并被误记为 other。最终仍需与 target sched_waking
            # 使用同一个 current TID，且时间足够接近，才允许配对。
            if (index($0,"kvm:kvm_timer_hrtimer_expire:")) {
                cause_event_tid=sample_tid($0)
                last_timer_cause_time[cause_event_tid]=timestamp
                last_timer_cause_detail[cause_event_tid]=$0
                sub(/^.*kvm:kvm_timer_hrtimer_expire:[[:space:]]*/,"", \
                    last_timer_cause_detail[cause_event_tid])
                attach_post_wake_cause(waiting_gap_row,timestamp,cause_event_tid, \
                    "kvm_timer",last_timer_cause_detail[cause_event_tid])
                next
            }

            if (index($0,"kvm:kvm_timer_emulate:")) {
                lowercase_event=tolower($0)
                if (lowercase_event ~ /should_fire[[:space:]]*[:=]?[[:space:]]*1/) {
                    cause_event_tid=sample_tid($0)
                    last_timer_cause_time[cause_event_tid]=timestamp
                    last_timer_cause_detail[cause_event_tid]=$0
                    sub(/^.*kvm:kvm_timer_emulate:[[:space:]]*/,"", \
                        last_timer_cause_detail[cause_event_tid])
                    attach_post_wake_cause(waiting_gap_row,timestamp,cause_event_tid, \
                        "kvm_timer",last_timer_cause_detail[cause_event_tid])
                }
                next
            }

            if (index($0,"kvm:kvm_timer_update_irq:")) {
                lowercase_event=tolower($0)
                if (lowercase_event ~ /level[[:space:]]*[:=]?[[:space:]]*1/) {
                    cause_event_tid=sample_tid($0)
                    last_timer_cause_time[cause_event_tid]=timestamp
                    last_timer_cause_detail[cause_event_tid]=$0
                    sub(/^.*kvm:kvm_timer_update_irq:[[:space:]]*/,"", \
                        last_timer_cause_detail[cause_event_tid])
                    attach_post_wake_cause(waiting_gap_row,timestamp,cause_event_tid, \
                        "kvm_timer",last_timer_cause_detail[cause_event_tid])
                }
                next
            }

            if (index($0,"kvm:kvm_irq_line:")) {
                lowercase_event=tolower($0)
                if (lowercase_event ~ /level[[:space:]]*[:=]?[[:space:]]*1/) {
                    cause_event_tid=sample_tid($0)
                    last_irq_cause_time[cause_event_tid]=timestamp
                    last_irq_cause_detail[cause_event_tid]=$0
                    sub(/^.*kvm:kvm_irq_line:[[:space:]]*/,"", \
                        last_irq_cause_detail[cause_event_tid])
                    attach_post_wake_cause(waiting_gap_row,timestamp,cause_event_tid, \
                        "virtual_irq",last_irq_cause_detail[cause_event_tid])
                }
                next
            }

            if (index($0,"kvm:vgic_update_irq_pending:")) {
                lowercase_event=tolower($0)
                if (lowercase_event ~ /level[[:space:]]*[:=]?[[:space:]]*1/) {
                    cause_event_tid=sample_tid($0)
                    last_irq_cause_time[cause_event_tid]=timestamp
                    last_irq_cause_detail[cause_event_tid]=$0
                    sub(/^.*kvm:vgic_update_irq_pending:[[:space:]]*/,"", \
                        last_irq_cause_detail[cause_event_tid])
                    attach_post_wake_cause(waiting_gap_row,timestamp,cause_event_tid, \
                        "virtual_irq",last_irq_cause_detail[cause_event_tid])
                }
                next
            }

            # kvm_vcpu_wakeup 由已经恢复执行的 target vCPU 自己打印。它不是
            # “谁唤醒了我”，但能说明 KVM halt path 是实际 wait 还是仅轮询，
            # 并给出 KVM 记录的总 block 时间。
            if (index($0,"kvm:kvm_vcpu_wakeup:")) {
                if (sample_tid($0) != target_tid+0) next
                kvm_wakeup_target_count++
                kvm_wakeup_body=$0
                sub(/^.*kvm:kvm_vcpu_wakeup:[[:space:]]*/,"",kvm_wakeup_body)
                lowercase_event=tolower(kvm_wakeup_body)
                parsed_block_ns=kvm_wakeup_body
                sub(/^.*time[[:space:]]+/,"",parsed_block_ns)
                sub(/[[:space:]]+ns.*$/,"",parsed_block_ns)
                if (parsed_block_ns !~ /^[0-9]+$/) parsed_block_ns=""
                parsed_waited=(lowercase_event ~ \
                    /(^|[[:space:]])wait[[:space:]]+time/) ? 1 : 0
                parsed_valid=(lowercase_event ~ \
                    /polling[[:space:]]+valid/) ? 1 : 0

                if (parsed_waited) kvm_waited_count++
                else kvm_polled_count++
                if (!parsed_valid) kvm_invalid_count++

                if (last_switch_in_row > 0) {
                    row_has_kvm_wakeup[last_switch_in_row]=1
                    row_kvm_block_ns[last_switch_in_row]=parsed_block_ns
                    row_kvm_waited[last_switch_in_row]=parsed_waited
                    row_kvm_valid[last_switch_in_row]=parsed_valid
                } else {
                    orphan_kvm_wakeup++
                }
                next
            }

            # 一次 WFI/WFE 应在 vCPU 真正睡眠前与后续 sched_switch 配对。
            # 若已经重新进入 guest 仍未发生主动调出，说明旧 WFX 不能再用于
            # 解释后面的 switch；把它记入 unmatched_wfx 作为数据质量提示。
            if (index($0,"kvm:kvm_entry:") || index($0,"kvm:kvm_entry_v2:")) {
                if (sample_tid($0) != target_tid+0) next

                # 极少数 perf.data 在没有 PERF_RECORD_LOST、文件也能正常解码
                # 的情况下，会把同一个 target KVM tracepoint 样本完整输出
                # 两次。其特征是整行文本（含 TID、CPU、时间戳、事件和载荷）
                # 与目标 vCPU 的上一条 KVM entry/exit 完全相同。
                #
                # 这里只去掉“逐字完全相同”的重复样本；相同时间戳但载荷不同、
                # 或两个不相同的连续 entry 仍会进入下方状态机并触发严格的
                # entry/exit 不配对检查，避免掩盖真正的丢样或时序错误。
                if ($0 == last_target_kvm_event_line) {
                    duplicate_target_kvm_events++
                    duplicate_target_kvm_entries++
                    next
                }
                last_target_kvm_event_line=$0

                target_kvm_entry_count++
                if (guest_entry_time!="") unmatched_kvm_entry++
                guest_entry_time=timestamp
                if (pending_wfx!="") unmatched_wfx++
                pending_wfx=""
                last_kvm_exit=""
                next
            }

            # 保存 target 最近一次 KVM exit 的原始上下文。它是 other 类型的
            # 人工排查线索，但不能仅凭某个 exit reason 判定主动调出。
            if (index($0,"kvm:kvm_exit:") || index($0,"kvm:kvm_exit_v2:")) {
                if (sample_tid($0) != target_tid+0) next

                # 与 entry 分支使用同一条“整行完全相同”去重规则。用户本次
                # 失败样本就是一个 DABT_LOW exit 在同一纳秒被原样输出两次；
                # 第一条正常结束 guest 区间，第二条不能再计为一次新 exit。
                if ($0 == last_target_kvm_event_line) {
                    duplicate_target_kvm_events++
                    duplicate_target_kvm_exits++
                    next
                }
                last_target_kvm_event_line=$0

                target_kvm_exit_count++
                if (guest_entry_time!="") {
                    guest_interval=timestamp-guest_entry_time
                    if (guest_interval >= 0) guest_running_s+=guest_interval
                    else negative_guest_interval++
                    guest_entry_time=""
                } else {
                    unmatched_kvm_exit++
                }
                last_kvm_exit=$0
                sub(/^.*kvm:kvm_exit(_v2)?:[[:space:]]*/,"",last_kvm_exit)
                next
            }

            # arm64 不同内核版本的打印格式可能是“executed wfe”、
            # is_wfe=1、is_wfe: 1、wfe=1 或 wfe: 1；其余视为 WFI。
            if (index($0,"kvm:kvm_wfx_arm64:")) {
                if (sample_tid($0) != target_tid+0) next
                if (pending_wfx!="") unmatched_wfx++
                lowercase_event=tolower($0)
                pending_wfx=(lowercase_event ~ /(executed[[:space:]]+wfe|is_wfe[[:space:]]*[:=][[:space:]]*1|wfe[[:space:]]*[:=][[:space:]]*1)/) \
                    ? "wfe" : "wfi"
                next
            }

            # sched_waking 在真正执行 try_to_wake_up 的上下文中触发。字段 pid
            # 是被唤醒的 target；perf 前缀的 TGID/TID/comm 是实际唤醒者。
            if (index($0,"sched:sched_waking:")) {
                awakened_pid=parse_sched_wakeup_pid($0)
                if (awakened_pid != target_tid+0) next

                waking_target_count++
                if (waiting_gap_row > 0 && \
                    row_waking_time[waiting_gap_row]=="") {
                    row_waking_time[waiting_gap_row]=timestamp
                    attach_waker_and_cause(waiting_gap_row,timestamp,$0)
                } else {
                    orphan_waking++
                }
                next
            }

            # sched_wakeup 表示 target 已经变成 TASK_RUNNING。它与下一次
            # sched_switch-in 之间的时间，就是超分竞争造成的 ready wait。
            if (index($0,"sched:sched_wakeup:")) {
                awakened_pid=parse_sched_wakeup_pid($0)
                if (awakened_pid != target_tid+0) next

                wakeup_target_count++
                if (waiting_gap_row > 0 && \
                    row_wakeup_time[waiting_gap_row]=="") {
                    row_wakeup_time[waiting_gap_row]=timestamp

                    # 极少数路径可能只看到 sched_wakeup，没有对应
                    # sched_waking。此时仍可从 sched_wakeup 的 current 前缀
                    # 得到同一个唤醒者，并按相同规则匹配紧邻 KVM 原因事件。
                    # 不伪造 waking_time，质量指标仍会如实记录缺失数量。
                    if (row_waker_tid[waiting_gap_row]=="")
                        attach_waker_and_cause(waiting_gap_row,timestamp,$0)
                } else {
                    orphan_wakeup++
                }
                next
            }

            if (!index($0,"sched:sched_switch:")) next
            switch_body=$0
            sub(/^.*sched:sched_switch:[[:space:]]*/,"",switch_body)
            if (!parse_sched_switch(switch_body)) {
                unparsed_sched++
                next
            }
            previous_pid=parsed_previous_pid
            next_pid=parsed_next_pid

            # target 被调出：结束一个时间片，同时判定主动/被动。
            if (previous_pid == target_tid+0) {
                previous_state=parsed_previous_state
                next_process_name=parsed_next_comm
                exit_context_for_row=last_kvm_exit

                # 时间片定义：本次调出时间 - 上一次调入时间。
                # 正常实验中 target 在 GO 前处于阻塞状态，因此第一个调入事件
                # 会落在窗口内；若缺少调入配对，则该次调出仍计数但不进入分布。
                current_slice_ms=""
                if (last_switch_in_time!="") {
                    current_slice_ms=(timestamp-last_switch_in_time)*1000
                    if (current_slice_ms >= 0) {
                        slice_count++
                        slice_values[slice_count]=current_slice_ms
                        slice_sum_ms+=current_slice_ms
                    } else {
                        current_slice_ms=""
                    }
                }

                if (previous_state ~ /^R/) {
                    # R/R+：线程仍 runnable，是被调度器抢占的被动调出。
                    switch_kind="passive"
                    switch_subtype="passive"
                    passive_total++

                    # 故意保留 pending_wfx：WFI/WFE 的内核处理路径自身也可能
                    # 先被抢占，恢复后才真正阻塞；过早清除会误分到 other。
                } else {
                    # 非 R：线程因睡眠/阻塞放弃 CPU，是 Linux 意义的主动调出。
                    switch_kind="voluntary"
                    switch_subtype=(pending_wfx=="" ? "other" : pending_wfx)
                    voluntary_total++
                    voluntary_by_reason[switch_subtype]++
                    pending_wfx=""
                    last_kvm_exit=""
                }

                # 先保存这次调出；它的 gap 要等下一次 target 调入后才能确定。
                switch_row_count++
                row_out_time[switch_row_count]=timestamp
                row_kind[switch_row_count]=switch_kind
                row_subtype[switch_row_count]=switch_subtype
                row_previous_state[switch_row_count]=previous_state
                row_next_name[switch_row_count]=next_process_name
                row_next_pid[switch_row_count]=next_pid
                row_exit_context[switch_row_count]=exit_context_for_row
                if (current_slice_ms!="") {
                    row_has_slice[switch_row_count]=1
                    row_slice_ms[switch_row_count]=current_slice_ms
                }

                waiting_gap_row=switch_row_count
                last_switch_in_time=""
            }

            # target 被调入：结束上一次调出后的 gap，并开始一个新时间片。
            if (next_pid == target_tid+0) {
                if (waiting_gap_row > 0) {
                    completed_gap_row=waiting_gap_row
                    current_gap_ms=(timestamp-row_out_time[waiting_gap_row])*1000
                    if (current_gap_ms >= 0) {
                        gap_count++
                        gap_values[gap_count]=current_gap_ms
                        gap_sum_ms+=current_gap_ms
                        row_has_gap[waiting_gap_row]=1
                        row_next_in_time[waiting_gap_row]=timestamp
                        row_gap_ms[waiting_gap_row]=current_gap_ms
                    }

                    # 只对确实捕获到 sched_wakeup 的 gap 拆分：
                    #   blocked = switch-out -> wakeup
                    #   ready   = wakeup -> switch-in
                    if (row_wakeup_time[waiting_gap_row]!="") {
                        current_blocked_ms= \
                            (row_wakeup_time[waiting_gap_row]- \
                             row_out_time[waiting_gap_row])*1000
                        current_ready_ms= \
                            (timestamp-row_wakeup_time[waiting_gap_row])*1000

                        if (current_blocked_ms >= 0 && current_ready_ms >= 0) {
                            row_blocked_ms[waiting_gap_row]=current_blocked_ms
                            row_ready_ms[waiting_gap_row]=current_ready_ms
                            row_has_wakeup_split[waiting_gap_row]=1

                            # 阻塞/排队分布只统计主动调出。被动调出本来就一直
                            # runnable，不应出现 sched_wakeup。
                            if (row_kind[waiting_gap_row]=="voluntary") {
                                blocked_count++
                                blocked_values[blocked_count]=current_blocked_ms
                                blocked_sum_ms+=current_blocked_ms
                                ready_count++
                                ready_values[ready_count]=current_ready_ms
                                ready_sum_ms+=current_ready_ms
                            }
                        } else {
                            invalid_wakeup_order++
                        }
                    }

                    last_switch_in_row=completed_gap_row
                    waiting_gap_row=0
                }
                last_switch_in_time=timestamp
            }
        }

        END {
            if (pending_wfx!="") unmatched_wfx++
            if (guest_entry_time!="") unmatched_kvm_entry++

            # 若采集停止时 target 仍在 CPU 上，把最后一段截到 perf.data 的最后
            # 一个样本。该时间与 sched_switch 使用相同的 perf 事件时钟，不与
            # CLOCK_REALTIME 混算。
            if (last_switch_in_time!="" && last_event_time!="" && \
                last_switch_in_time < last_event_time) {
                final_slice_ms=(last_event_time-last_switch_in_time)*1000
                if (final_slice_ms >= 0) {
                    slice_count++
                    slice_values[slice_count]=final_slice_ms
                    slice_sum_ms+=final_slice_ms
                }
            }

            # 排序后计算 avg/P50/P99；数组都是从下标 1 开始的连续数值数组。
            quicksort(slice_values,1,slice_count)
            quicksort(gap_values,1,gap_count)
            quicksort(blocked_values,1,blocked_count)
            quicksort(ready_values,1,ready_count)
            slice_avg_ms=(slice_count ? slice_sum_ms/slice_count : "")
            slice_p50_ms=percentile(slice_values,slice_count,0.50)
            slice_p99_ms=percentile(slice_values,slice_count,0.99)
            gap_avg_ms=(gap_count ? gap_sum_ms/gap_count : "")
            gap_p50_ms=percentile(gap_values,gap_count,0.50)
            gap_p99_ms=percentile(gap_values,gap_count,0.99)
            blocked_avg_ms=(blocked_count ? blocked_sum_ms/blocked_count : "")
            blocked_p50_ms=percentile(blocked_values,blocked_count,0.50)
            blocked_p99_ms=percentile(blocked_values,blocked_count,0.99)
            ready_avg_ms=(ready_count ? ready_sum_ms/ready_count : "")
            ready_p50_ms=percentile(ready_values,ready_count,0.50)
            ready_p99_ms=percentile(ready_values,ready_count,0.99)
            oncpu_s=slice_sum_ms/1000

            # kvm_entry -> kvm_exit 是 target 实际执行 guest 指令的时间；
            # onCPU 减去该值，则是 vCPU 线程占有 CPU 但运行在 Host/KVM/
            # Firecracker 路径中的时间。
            host_vcpu_running_s=oncpu_s-guest_running_s
            if (host_vcpu_running_s < 0 && host_vcpu_running_s > -0.000001)
                host_vcpu_running_s=0
            else if (host_vcpu_running_s < 0)
                negative_host_time=1

            voluntary_per_guest_s=(guest_running_s > 0 ? \
                voluntary_total/guest_running_s : 0)
            wfi_per_guest_s=(guest_running_s > 0 ? \
                voluntary_by_reason["wfi"]/guest_running_s : 0)
            kvm_exit_per_guest_s=(guest_running_s > 0 ? \
                target_kvm_exit_count/guest_running_s : 0)

            wfi_percent=(voluntary_total ? \
                100*voluntary_by_reason["wfi"]/voluntary_total : 0)
            wfe_percent=(voluntary_total ? \
                100*voluntary_by_reason["wfe"]/voluntary_total : 0)
            other_percent=(voluntary_total ? \
                100*voluntary_by_reason["other"]/voluntary_total : 0)
            switch_out_total=voluntary_total+passive_total

            # 只在 v15 原始数据中统计唤醒原因。没有下一次 switch-in 的最后一行
            # 是采集窗口右删失，不把它误报成“缺失 sched_wakeup”。
            if (wakeup_events_recorded+0 == 1) {
                for (row_index=1; row_index<=switch_row_count; row_index++) {
                    if (row_kind[row_index]!="voluntary") continue

                    if (!row_has_gap[row_index]) {
                        right_censored_voluntary++
                        continue
                    }

                    if (row_waking_time[row_index]=="")
                        voluntary_missing_waking++

                    if (row_wakeup_time[row_index]!="") {
                        voluntary_with_wakeup++
                        current_cause=row_wake_cause[row_index]
                        if (current_cause=="") current_cause="other"
                        wake_cause_count[current_cause]++

                        if (row_post_wake_reclassified[row_index]) {
                            post_wake_reclassified_total++
                            if (current_cause=="kvm_timer")
                                post_wake_reclassified_timer++
                            else if (current_cause=="virtual_irq")
                                post_wake_reclassified_irq++
                        }
                    } else {
                        voluntary_missing_wakeup++
                    }
                }
            }

            # 明细到 END 才写出，因为每次调出的 gap 要等后续调入事件才能获得。
            print "out_time,kind,subtype,prev_state,slice_ms,next_comm,next_pid," \
                  "last_kvm_exit,next_in_time,gap_ms,waking_time,wakeup_time," \
                  "blocked_ms,ready_wait_ms,waker_comm,waker_tgid,waker_tid," \
                  "wake_cause,wake_evidence,kvm_block_ns,kvm_waited,kvm_valid" \
                  > event_file
            for (row_index=1; row_index<=switch_row_count; row_index++) {
                slice_text=(row_has_slice[row_index] ? \
                    sprintf("%.6f",row_slice_ms[row_index]) : "")
                next_in_text=(row_has_gap[row_index] ? \
                    sprintf("%.9f",row_next_in_time[row_index]) : "")
                gap_text=(row_has_gap[row_index] ? \
                    sprintf("%.6f",row_gap_ms[row_index]) : "")
                waking_text=(row_waking_time[row_index]!="" ? \
                    sprintf("%.9f",row_waking_time[row_index]) : "")
                wakeup_text=(row_wakeup_time[row_index]!="" ? \
                    sprintf("%.9f",row_wakeup_time[row_index]) : "")
                blocked_text=(row_has_wakeup_split[row_index] ? \
                    sprintf("%.6f",row_blocked_ms[row_index]) : "")
                ready_text=(row_has_wakeup_split[row_index] ? \
                    sprintf("%.6f",row_ready_ms[row_index]) : "")
                waker_tgid_text=(row_waker_tid[row_index]!="" ? \
                    row_waker_tgid[row_index] : "")
                waker_tid_text=(row_waker_tid[row_index]!="" ? \
                    row_waker_tid[row_index] : "")
                kvm_block_text=(row_has_kvm_wakeup[row_index] ? \
                    row_kvm_block_ns[row_index] : "")
                kvm_waited_text=(row_has_kvm_wakeup[row_index] ? \
                    row_kvm_waited[row_index] : "")
                kvm_valid_text=(row_has_kvm_wakeup[row_index] ? \
                    row_kvm_valid[row_index] : "")

                printf "%.9f,%s,%s,%s,%s,%s,%d,%s,%s,%s," \
                       "%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n", \
                    row_out_time[row_index],row_kind[row_index],row_subtype[row_index], \
                    row_previous_state[row_index],slice_text, \
                    csv_quote(row_next_name[row_index]),row_next_pid[row_index], \
                    csv_quote(row_exit_context[row_index]),next_in_text,gap_text, \
                    waking_text,wakeup_text,blocked_text,ready_text, \
                    csv_quote(row_waker_comm[row_index]),waker_tgid_text, \
                    waker_tid_text,row_wake_cause[row_index], \
                    csv_quote(row_wake_evidence[row_index]),kvm_block_text, \
                    kvm_waited_text,kvm_valid_text \
                    >> event_file
            }

            print "mode,target,round,wall_s,voluntary_total,voluntary_wfi,voluntary_wfe," \
                  "voluntary_other,passive_total,wfi_pct,wfe_pct,other_pct,unmatched_wfx," \
                  "switch_out_total,slice_count,slice_avg_ms,slice_p50_ms,slice_p99_ms," \
                  "gap_count,gap_avg_ms,gap_p50_ms,gap_p99_ms,oncpu_s," \
                  "unparsed_sched,guest_running_s,host_vcpu_running_s," \
                  "voluntary_per_guest_s,wfi_per_guest_s,kvm_exit_per_guest_s," \
                  "target_kvm_entry,target_kvm_exit,wakeup_events_recorded," \
                  "sched_waking_target,sched_wakeup_target,voluntary_with_wakeup," \
                  "voluntary_missing_wakeup,right_censored_voluntary," \
                  "wake_kvm_timer,wake_virtual_irq,wake_other,blocked_count," \
                  "blocked_avg_ms,blocked_p50_ms,blocked_p99_ms,ready_count," \
                  "ready_avg_ms,ready_p50_ms,ready_p99_ms," \
                  "kvm_vcpu_wakeup_target,kvm_waited,kvm_polled,kvm_invalid," \
                  "orphan_waking,orphan_wakeup,orphan_kvm_wakeup," \
                  "invalid_wakeup_order,unmatched_kvm_entry,unmatched_kvm_exit," \
                  "negative_guest_interval,negative_host_time," \
                  "voluntary_missing_waking,duplicate_target_kvm_events" \
                  > summary_file

            printf "%s,%s,%s,%.6f,%d,%d,%d,%d,%d,%.2f,%.2f,%.2f,%d,%d,%d," \
                   "%s,%s,%s,%d,%s,%s,%s,%.9f,%d", \
                experiment_mode,target,round_id,wall_end-wall_start,voluntary_total, \
                voluntary_by_reason["wfi"],voluntary_by_reason["wfe"], \
                voluntary_by_reason["other"],passive_total,wfi_percent,wfe_percent, \
                other_percent,unmatched_wfx,switch_out_total,slice_count, \
                (slice_count?sprintf("%.6f",slice_avg_ms):""), \
                (slice_count?sprintf("%.6f",slice_p50_ms):""), \
                (slice_count?sprintf("%.6f",slice_p99_ms):""),gap_count, \
                (gap_count?sprintf("%.6f",gap_avg_ms):""), \
                (gap_count?sprintf("%.6f",gap_p50_ms):""), \
                (gap_count?sprintf("%.6f",gap_p99_ms):""),oncpu_s,unparsed_sched \
                >> summary_file

            printf ",%.9f,%.9f,%.6f,%.6f,%.6f,%d,%d,%d,%d,%d,%d,%d,%d," \
                   "%d,%d,%d,%d,%s,%s,%s,%d,%s,%s,%s,%d,%d,%d,%d,%d,%d," \
                   "%d,%d,%d,%d,%d,%d,%d,%d\n", \
                guest_running_s,host_vcpu_running_s,voluntary_per_guest_s, \
                wfi_per_guest_s,kvm_exit_per_guest_s,target_kvm_entry_count, \
                target_kvm_exit_count,wakeup_events_recorded+0, \
                waking_target_count,wakeup_target_count,voluntary_with_wakeup, \
                voluntary_missing_wakeup,right_censored_voluntary, \
                wake_cause_count["kvm_timer"],wake_cause_count["virtual_irq"], \
                wake_cause_count["other"],blocked_count, \
                (blocked_count?sprintf("%.6f",blocked_avg_ms):""), \
                (blocked_count?sprintf("%.6f",blocked_p50_ms):""), \
                (blocked_count?sprintf("%.6f",blocked_p99_ms):""),ready_count, \
                (ready_count?sprintf("%.6f",ready_avg_ms):""), \
                (ready_count?sprintf("%.6f",ready_p50_ms):""), \
                (ready_count?sprintf("%.6f",ready_p99_ms):""), \
                kvm_wakeup_target_count,kvm_waited_count,kvm_polled_count, \
                kvm_invalid_count,orphan_waking,orphan_wakeup,orphan_kvm_wakeup, \
                invalid_wakeup_order,unmatched_kvm_entry,unmatched_kvm_exit, \
                negative_guest_interval,negative_host_time, \
                voluntary_missing_waking,duplicate_target_kvm_events \
                >> summary_file

            # 原因表用于直接汇总“多出来的主动调度由什么唤醒”。百分比分母是
            # 本轮成功捕获 sched_wakeup 的主动调出，不包含窗口末尾右删失行。
            print "mode,target,round,cause,count,pct_of_observed_voluntary_wakeups" \
                > cause_summary_file
            if (wakeup_events_recorded+0 == 1) {
                for (cause_index=1; cause_index<=3; cause_index++) {
                    current_cause=(cause_index==1 ? "kvm_timer" : \
                        (cause_index==2 ? "virtual_irq" : "other"))
                    cause_pct=(voluntary_with_wakeup ? \
                        100*wake_cause_count[current_cause]/voluntary_with_wakeup : 0)
                    printf "%s,%s,%s,%s,%d,%.2f\n", \
                        experiment_mode,target,round_id,current_cause, \
                        wake_cause_count[current_cause],cause_pct \
                        >> cause_summary_file
                }
                printf "%s,%s,%s,missing_wakeup,%d,\n", \
                    experiment_mode,target,round_id,voluntary_missing_wakeup \
                    >> cause_summary_file
                printf "%s,%s,%s,right_censored,%d,\n", \
                    experiment_mode,target,round_id,right_censored_voluntary \
                    >> cause_summary_file
            } else {
                printf "%s,%s,%s,not_recorded,0,\n", \
                    experiment_mode,target,round_id >> cause_summary_file
            }

            printf "switch_out=%d, voluntary=%d (wfi=%d, wfe=%d, other=%d), " \
                   "passive=%d, slice_avg_ms=%s, gap_avg_ms=%s, oncpu_s=%.6f, " \
                   "guest_s=%.6f, host_vcpu_s=%.6f, wakeup_capture=%d, " \
                   "wake(timer=%d, irq=%d, other=%d, missing=%d), " \
                   "post_wake_reclassified=%d(timer=%d,irq=%d), " \
                   "kvm_exact_duplicates=%d, unparsed_sched=%d\n", \
                switch_out_total,voluntary_total,voluntary_by_reason["wfi"], \
                voluntary_by_reason["wfe"],voluntary_by_reason["other"],passive_total, \
                (slice_count?sprintf("%.6f",slice_avg_ms):"NA"), \
                (gap_count?sprintf("%.6f",gap_avg_ms):"NA"),oncpu_s, \
                guest_running_s,host_vcpu_running_s,wakeup_events_recorded+0, \
                wake_cause_count["kvm_timer"],wake_cause_count["virtual_irq"], \
                wake_cause_count["other"],voluntary_missing_wakeup, \
                post_wake_reclassified_total,post_wake_reclassified_timer, \
                post_wake_reclassified_irq,duplicate_target_kvm_events, \
                unparsed_sched
        }
    ' "$RUN_DIR/perf.txt" | tee "$RUN_DIR/summary.txt"

    read -r \
        summary_columns \
        summary_unparsed \
        summary_missing_wakeup \
        summary_missing_waking \
        summary_parsed_waking \
        summary_parsed_wakeup \
        summary_invalid_order \
        summary_unmatched_entry \
        summary_unmatched_exit \
        summary_negative_guest \
        summary_negative_host \
        summary_duplicate_kvm \
        < <(
            awk -F, '
                NR==1 {
                    for (column=1; column<=NF; column++)
                        index_of[$column]=column
                    next
                }
                NR==2 {
                    print NF,
                          $(index_of["unparsed_sched"]),
                          $(index_of["voluntary_missing_wakeup"]),
                          $(index_of["voluntary_missing_waking"]),
                          $(index_of["sched_waking_target"]),
                          $(index_of["sched_wakeup_target"]),
                          $(index_of["invalid_wakeup_order"]),
                          $(index_of["unmatched_kvm_entry"]),
                          $(index_of["unmatched_kvm_exit"]),
                          $(index_of["negative_guest_interval"]),
                          $(index_of["negative_host_time"]),
                          $(index_of["duplicate_target_kvm_events"])
                }
            ' "$RUN_DIR/summary.csv"
        )

    [[ $summary_columns == 62 ]] || \
        die "summary.csv 列数异常：实际=$summary_columns，预期=62"
    [[ $summary_unparsed == 0 ]] || \
        die "存在无法解析的 sched_switch：$summary_unparsed"
    [[ $summary_invalid_order == 0 ]] || \
        die "sched_wakeup/switch-in 时间顺序异常：$summary_invalid_order"
    [[ $summary_unmatched_entry == 0 && $summary_unmatched_exit == 0 ]] || \
        die "target KVM entry/exit 不配对：entry=$summary_unmatched_entry exit=$summary_unmatched_exit"
    [[ $summary_negative_guest == 0 && $summary_negative_host == 0 ]] || \
        die "guest/Host-vCPU 时间出现负值"

    if (( summary_duplicate_kvm > 0 )); then
        log "提示：已忽略 target KVM 完全重复样本=$summary_duplicate_kvm；原始 perf.data 保持不变，真正的不配对仍会报错"
    fi

    if (( wakeup_events_recorded == 1 )); then
        [[ $summary_parsed_waking == "$sched_waking_count" ]] || \
            die "sched_waking 文本解析数量不一致：原始=$sched_waking_count 解析=$summary_parsed_waking"
        [[ $summary_parsed_wakeup == "$sched_wakeup_count" ]] || \
            die "sched_wakeup 文本解析数量不一致：原始=$sched_wakeup_count 解析=$summary_parsed_wakeup"

        if [[ $summary_missing_wakeup != 0 ]]; then
            log "警告：主动调出缺少 sched_wakeup=$summary_missing_wakeup；请勿直接做原因占比"
        elif [[ $summary_missing_waking != 0 ]]; then
            log "提示：有 $summary_missing_waking 次主动调出缺少 sched_waking，已用同一唤醒路径中的 sched_wakeup 上下文回填原因；质量计数仍保留"
        fi
    fi

    # run.env 记录的是“采集时”使用的脚本版本，重新分析旧 perf.data 时不能
    # 覆盖它。单独保存分析器版本，确保以后能够区分 v15.3 单向关联结果与
    # v15.4 双向关联结果以及 v15.5 精确重复样本处理结果。
    {
        printf 'analysis_script_version=%s\n' "$SCRIPT_VERSION"
        printf 'analysis_script_sha256=%s\n' \
            "$(sha256sum "$0" | awk '{print $1}')"
        printf 'wake_cause_association=%s\n' \
            "bidirectional_same_waker_before_switch_in"
        printf 'wake_cause_window_us=%s\n' "$WAKE_CAUSE_WINDOW_US"
        printf 'target_kvm_duplicate_policy=%s\n' \
            "deduplicate_byte_identical_consecutive_target_kvm_event"
    } >"$RUN_DIR/analysis.env"
}

# 对同一 target、同一轮次的两份汇总做差。允许的方向是：
#   n1 -> n5：      观察普通 CFS 超分的影响；
#   n5 -> n5_fifo：观察只提高 target vCPU 优先级后的变化。
#
# “share_of_extra”分母是右侧模式主动调出数 - 左侧模式主动调出数。
# 当分母为负数时，占比也带符号，表示右侧模式减少了主动调出；因此解释
# FIFO 对照时应同时看 delta，不能把该列当作无符号构成比例。
compare_runs() {
    local left_summary=$1 right_summary=$2 comparison_output=$3
    [[ -r $left_summary && -r $right_summary ]] || \
        die "待比较的 summary.csv 不可读"

    awk -F, -v output_file="$comparison_output" '
        NR==FNR && FNR==2 {
            n1_column_count=NF
            for (column=1; column<=NF; column++) n1_row[column]=$column
            next
        }
        FNR==2 {
            n5_column_count=NF
            for (column=1; column<=NF; column++) n5_row[column]=$column
        }

        function print_metric(metric_name, csv_column, is_voluntary_component, decimals,
                              n1_value, n5_value, delta, share_of_extra,
                              n1_text, n5_text, delta_text) {
            n1_value=n1_row[csv_column]+0
            n5_value=n5_row[csv_column]+0
            delta=n5_value-n1_value
            share_of_extra=(is_voluntary_component && extra_voluntary!=0) \
                ? sprintf("%.2f",100*delta/extra_voluntary) : ""
            n1_text=sprintf("%.*f",decimals,n1_value)
            n5_text=sprintf("%.*f",decimals,n5_value)
            delta_text=sprintf("%.*f",decimals,delta)
            print metric_name "," n1_text "," n5_text "," delta_text "," \
                  share_of_extra >> output_file
            printf "%-18s %s=%-14s %s=%-14s delta=%-14s share=%s\n", \
                metric_name,left_mode,n1_text,right_mode,n5_text,delta_text, \
                (share_of_extra=="" ? "-" : share_of_extra "%")
        }

        END {
            left_mode=n1_row[1]
            right_mode=n5_row[1]
            valid_direction=(left_mode=="n1" && right_mode=="n5") || \
                            (left_mode=="n5" && right_mode=="n5_fifo")

            # 防止误拿不同 workload、不同轮次或方向颠倒的两个文件比较。
            if (n1_column_count < 23 || n5_column_count < 23 || \
                !valid_direction || \
                n1_row[2]!=n5_row[2] || n1_row[3]!=n5_row[3]) {
                print "ERROR: 只允许比较同 target、同轮次的 n1->n5 或 n5->n5_fifo summary" \
                    > "/dev/stderr"
                exit 2
            }

            extra_voluntary=(n5_row[5]+0)-(n1_row[5]+0)
            print "metric," left_mode "," right_mode \
                  ",delta,share_of_extra_voluntary_pct" > output_file
            printf "target=%s round=%s comparison=%s->%s extra_voluntary=%d\n", \
                n1_row[2],n1_row[3],left_mode,right_mode,extra_voluntary
            print_metric("switch_out_total",14,0,0)
            print_metric("voluntary",5,0,0)
            print_metric("wfi",6,1,0)
            print_metric("wfe",7,1,0)
            print_metric("other",8,1,0)
            print_metric("passive",9,0,0)
            print_metric("slice_avg_ms",16,0,6)
            print_metric("slice_p50_ms",17,0,6)
            print_metric("slice_p99_ms",18,0,6)
            print_metric("gap_avg_ms",20,0,6)
            print_metric("gap_p50_ms",21,0,6)
            print_metric("gap_p99_ms",22,0,6)
            print_metric("oncpu_s",23,0,9)
            if (n1_column_count >= 60 && n5_column_count >= 60) {
                print_metric("guest_running_s",25,0,9)
                print_metric("host_vcpu_running_s",26,0,9)
                print_metric("voluntary_per_guest_s",27,0,6)
                print_metric("wfi_per_guest_s",28,0,6)
                print_metric("kvm_exit_per_guest_s",29,0,6)
                if (n1_row[32]+0 == 1 && n5_row[32]+0 == 1) {
                    print_metric("wake_kvm_timer",38,1,0)
                    print_metric("wake_virtual_irq",39,1,0)
                    print_metric("wake_other",40,1,0)
                    print_metric("blocked_avg_ms",42,0,6)
                    print_metric("blocked_p50_ms",43,0,6)
                    print_metric("blocked_p99_ms",44,0,6)
                    print_metric("ready_avg_ms",46,0,6)
                    print_metric("ready_p50_ms",47,0,6)
                    print_metric("ready_p99_ms",48,0,6)
                } else {
                    print "wakeup_reason_metrics=not_comparable"
                }
            }
            print "comparison_csv=" output_file
        }
    ' "$left_summary" "$right_summary"
}

# ================================ 主流程 =====================================

run_experiment() {
    # 第 1 步：解析并验证命令行。本脚本一次只运行一个实验 case。
    [[ $# -eq 3 ]] || { usage; return 2; }
    EXPERIMENT_MODE=$1
    TARGET_WORKLOAD=$2
    ROUND_ID=$3

    log "脚本版本=$SCRIPT_VERSION path=$(readlink -f "$0")"

    [[ $EXPERIMENT_MODE == n1 || $EXPERIMENT_MODE == n5 || \
       $EXPERIMENT_MODE == n5_fifo ]] || \
        die "实验模式必须是 n1、n5 或 n5_fifo"
    [[ $ROUND_ID =~ ^[0-9]+$ ]] || die "round 必须是非负整数"
    [[ $KEEP_DISKS == 0 || $KEEP_DISKS == 1 ]] || die "KEEP_DISKS 只能是 0 或 1"
    [[ $SAVE_REPLAY_LOG == 0 || $SAVE_REPLAY_LOG == 1 ]] || \
        die "SAVE_REPLAY_LOG 只能是 0 或 1"
    [[ $REPLAY_LOG_MIB =~ ^[1-9][0-9]*$ ]] || \
        die "REPLAY_LOG_MIB 必须是正整数 MiB"
    [[ $WAKE_CAUSE_WINDOW_US =~ ^[1-9][0-9]*$ ]] || \
        die "WAKE_CAUSE_WINDOW_US 必须是正整数微秒"
    [[ $PERF_CONTROL_TIMEOUT =~ ^[1-9][0-9]*$ ]] || \
        die "PERF_CONTROL_TIMEOUT 必须是正整数秒"
    [[ $TARGET_FIFO_PRIORITY =~ ^[1-9][0-9]*$ ]] && \
        (( TARGET_FIFO_PRIORITY >= 1 && TARGET_FIFO_PRIORITY <= 99 )) || \
        die "TARGET_FIFO_PRIORITY 必须是 1～99 的整数"

    load_workload_table
    select_case_workloads
    check_environment
    parse_cluster_noise_cpus

    # 第 2 步：创建本轮独立结果目录，并把宿主机脚本移到 housekeeping 核。
    # 后续普通子进程会继承该 affinity；Firecracker 会显式改绑 TARGET_CPU。
    RUN_DIR="$RESULTS_DIR/$(date +%Y%m%d_%H%M%S)_${EXPERIMENT_MODE}_r${ROUND_ID}_${TARGET_WORKLOAD}_$$"
    mkdir -p "$RUN_DIR/work"
    printf 'vm_index,workload,pid,tid,comm\n' >"$RUN_DIR/threads.csv"
    write_guest_init "$RUN_DIR/guest-init.sh"
    trap cleanup_generated_resources EXIT INT TERM
    taskset -pc "$HOUSEKEEPING_CPU" $$ >/dev/null

    log "实验配置 mode=$EXPERIMENT_MODE target=$TARGET_WORKLOAD round=$ROUND_ID"
    log "CPU 配置 Firecracker全部线程=$TARGET_CPU 宿主机脚本/perf=$HOUSEKEEPING_CPU"
    log "本轮 VM: ${CASE_WORKLOADS[*]}"

    local vm_index
    if is_five_vm_mode; then
        # 第 3 步（N=5 / N=5-FIFO）：启动 CORE0_BG 台 background。
        # 全部 READY 后再一起 GO；它们各自在同一 guest 内反复 replay。
        # 等预热结束才创建 target，避免把 background 的 boot/git reset 计入测量。
        log "开始启动 ${CORE0_BG} 台 background VM"
        for ((vm_index=1; vm_index<${#CASE_WORKLOADS[@]}; vm_index++)); do
            launch_vm "$vm_index" background
        done
        for ((vm_index=1; vm_index<${#CASE_WORKLOADS[@]}; vm_index++)); do
            send_guest_go "$vm_index"
        done
        for ((vm_index=1; vm_index<${#CASE_WORKLOADS[@]}; vm_index++)); do
            wait_for_console_marker "${VM_CONSOLE_LOG[$vm_index]}" \
                "FC_BACKGROUND_STARTED name=${CASE_WORKLOADS[$vm_index]}" \
                "${VM_PROCESS_PID[$vm_index]}" "$READY_TIMEOUT" || \
                die "background 未开始循环: ${CASE_WORKLOADS[$vm_index]}"
        done
        log "background 已开始循环，预热 ${BACKGROUND_WARMUP}s"
        sleep "$BACKGROUND_WARMUP"

        # 第 3.5 步（v17）：在核0超分预热后，启动同 cluster 其他核上的噪声 VM。
        # 噪声先进入稳态循环，再起 target，保证 target 测量窗口内 L3 全程有压力。
        if is_cluster_noise_enabled; then
            start_cluster_noise
            log "cluster 噪声预热 ${CLUSTER_NOISE_WARMUP}s"
            sleep "$CLUSTER_NOISE_WARMUP"
        fi
    fi

    # 第 4 步：启动 target。此时 target 只完成 boot/reset，停在 READY，
    # 所以查 TID、核验绑核和启动 perf 都不会漏掉 replay 的开头。
    log "开始启动被观测 target VM"
    launch_vm 0 target
    TARGET_VCPU_TID=$(find_target_vcpu_tid "${VM_PROCESS_PID[0]}") || \
        die "找不到 target 的 fc_vcpu 0 线程"
    log "被观测线程 target_vcpu_tid=$TARGET_VCPU_TID"

    # 在 perf 启用前设置调度策略，因此 VM 启动、线程发现和 chrt 操作均不会
    # 进入测量窗口。scheduling.csv 会逐线程证明 n5_fifo 只修改了 target vCPU。
    configure_and_verify_thread_schedulers

    # 保存足以复核本轮配置的元数据。threads.csv 记录线程身份，
    # scheduling.csv 记录测量窗口开始前的最终调度策略和 affinity。
    printf 'target_firecracker_pid=%s\ntarget_vcpu_tid=%s\n' \
        "${VM_PROCESS_PID[0]}" "$TARGET_VCPU_TID" >"$RUN_DIR/run.env"
    printf 'mode=%s\ntarget=%s\nround=%s\ntarget_cpu=%s\nhousekeeping_cpu=%s\n' \
        "$EXPERIMENT_MODE" "$TARGET_WORKLOAD" "$ROUND_ID" \
        "$TARGET_CPU" "$HOUSEKEEPING_CPU" >>"$RUN_DIR/run.env"
    printf 'perf_version=%s\nkernel_release=%s\nkernel_image=%s\n' \
        "$(perf --version)" "$(uname -r)" "$(readlink -f "$KERNEL_IMAGE")" \
        >>"$RUN_DIR/run.env"
    printf 'script_version=%s\nscript_sha256=%s\ncapture_schema=%s\n' \
        "$SCRIPT_VERSION" "$(sha256sum "$0" | awk '{print $1}')" \
        "wakeup-root-cause-v2" >>"$RUN_DIR/run.env"
    printf 'target_sched_policy=%s\ntarget_sched_priority=%s\n' \
        "$TARGET_SCHED_POLICY" "$TARGET_SCHED_PRIORITY" >>"$RUN_DIR/run.env"
    printf 'fifo_target_vcpu_only=%s\nsched_rt_period_us=%s\nsched_rt_runtime_us=%s\n' \
        "$([[ $EXPERIMENT_MODE == n5_fifo ]] && printf 1 || printf 0)" \
        "$HOST_SCHED_RT_PERIOD_US" "$HOST_SCHED_RT_RUNTIME_US" \
        >>"$RUN_DIR/run.env"
    for ((vm_index=0; vm_index<${#CASE_WORKLOADS[@]}; vm_index++)); do
        printf 'vm_%s=%s\n' "$vm_index" "${CASE_WORKLOADS[$vm_index]}" >>"$RUN_DIR/run.env"
    done
    printf 'core0_bg=%s\ncluster_noise_enabled=%s\ncluster_noise_cpus=%s\n' \
        "$CORE0_BG" \
        "$(is_cluster_noise_enabled && printf 1 || printf 0)" \
        "${CLUSTER_NOISE_CPUS:-}" >>"$RUN_DIR/run.env"
    printf 'cluster_noise_workload=%s\ncluster_noise_count=%s\n' \
        "${CLUSTER_NOISE_WORKLOAD:-$TARGET_WORKLOAD}" "$NOISE_COUNT" \
        >>"$RUN_DIR/run.env"

    # 第 5 步：先启动 perf 进程，但事件保持 disabled；收到 enable ack 后才
    # 记录窗口起点并向 target 发送 GO。这样 boot、初始化以及 perf 启动期间
    # 的 READY 等待都不在 perf.data 中，同时 target replay 的开头不会漏采。
    start_perf_recording
    enable_perf_events
    WINDOW_START_TIME=$(date +%s.%N)
    send_guest_go 0
    log "target replay 已开始"

    wait_for_console_marker "${VM_CONSOLE_LOG[0]}" \
        "FC_TARGET_DONE name=$TARGET_WORKLOAD" "${VM_PROCESS_PID[0]}" \
        "$TARGET_TIMEOUT" || die "target 超时或 Firecracker 提前退出"
    WINDOW_END_TIME=$(date +%s.%N)

    # N=5 的 background 在 target DONE 后已经不属于测量负载。先暂停它们，
    # 避免持续的 KVM 事件使当前 perf 版本饿死 control FIFO；随后立即 disable。
    pause_background_vms_before_perf_disable
    disable_perf_events
    TARGET_EXIT_CODE=$(grep -F "FC_TARGET_DONE name=$TARGET_WORKLOAD" \
        "${VM_CONSOLE_LOG[0]}" | tail -1 | \
        sed -n 's/.* rc=\([0-9][0-9]*\).*/\1/p')

    # 这里的 realtime 只用于计算 workload 墙钟耗时；perf 样本采用内核默认
    # 事件时钟，二者不直接比较。精确采集边界由 enable/disable ack 保证。
    printf 'window_start_realtime=%s\nwindow_end_realtime=%s\n' \
        "$WINDOW_START_TIME" "$WINDOW_END_TIME" >>"$RUN_DIR/run.env"
    printf 'perf_control=%s\nperf_event_clock=%s\n' \
        "delay_-1_with_ack" "kernel_default" >>"$RUN_DIR/run.env"
    printf 'perf_disable_ack_ms=%s\nbackground_paused_before_disable=%s\n' \
        "${PERF_DISABLE_ACK_MS:-NA}" \
        "$(is_five_vm_mode && printf 1 || printf 0)" \
        >>"$RUN_DIR/run.env"
    printf 'save_replay_log=%s\nreplay_log_mib=%s\n' \
        "$SAVE_REPLAY_LOG" "$REPLAY_LOG_MIB" >>"$RUN_DIR/run.env"
    printf 'wake_cause_window_us=%s\n' "$WAKE_CAUSE_WINDOW_US" \
        >>"$RUN_DIR/run.env"

    # 第 6 步：先让 perf 正常落盘。确认 perf 已完全停止后，再通知 target
    # 通过串口导出 replay 日志；因此日志打印不会被采入 perf.data。
    stop_perf_recording

    if [[ $SAVE_REPLAY_LOG == 1 ]]; then
        send_guest_command 0 DUMP_REPLAY_LOG
        wait_for_console_marker "${VM_CONSOLE_LOG[0]}" \
            "FC_REPLAY_LOG_END name=$TARGET_WORKLOAD" "${VM_PROCESS_PID[0]}" \
            "$READY_TIMEOUT" || die "等待 target replay 日志导出超时"
        extract_target_replay_log
        printf 'replay_log_bytes=%s\n' "$(wc -c <"$RUN_DIR/replay.log")" \
            >>"$RUN_DIR/run.env"
        log "target replay 日志已保存: $RUN_DIR/replay.log"
    fi

    # 第 7 步：停止所有 VM，生成调度明细和汇总。
    stop_all_vms
    analyze_perf_data

    log "实验完成 run_dir=$RUN_DIR"
    log "target 返回码=${TARGET_EXIT_CODE:-unknown}"
    [[ ${TARGET_EXIT_CODE:-1} == 0 ]]
}

# 对已有 run_dir 重新执行报告和 AWK 后处理，不启动 Firecracker，也不重新
# 采集 perf.data。这个入口主要用于升级分析逻辑后复用已有的原始数据。
analyze_existing_run() {
    local recorded_kernel_image recorded_cause_window derived_file backup_file

    [[ $# -eq 1 ]] || { usage; return 2; }

    RUN_DIR=$(readlink -f "$1")
    [[ -d $RUN_DIR ]] || die "结果目录不存在: $RUN_DIR"
    [[ -r $RUN_DIR/run.env ]] || die "缺少结果元数据: $RUN_DIR/run.env"
    [[ -r $RUN_DIR/perf.data ]] || die "缺少原始采集数据: $RUN_DIR/perf.data"

    # run.env 由本脚本以 key=value 形式生成。这里逐个读取固定键，不直接
    # source 文件，避免其中的值被 Shell 当作命令解释。
    run_env_value() {
        sed -n "s/^$1=//p" "$RUN_DIR/run.env" | tail -1
    }

    EXPERIMENT_MODE=$(run_env_value mode)
    TARGET_WORKLOAD=$(run_env_value target)
    ROUND_ID=$(run_env_value round)
    TARGET_VCPU_TID=$(run_env_value target_vcpu_tid)
    WINDOW_START_TIME=$(run_env_value window_start_realtime)
    WINDOW_END_TIME=$(run_env_value window_end_realtime)
    HOUSEKEEPING_CPU=$(run_env_value housekeeping_cpu)
    VM_PROCESS_PID[0]=$(run_env_value target_firecracker_pid)
    recorded_kernel_image=$(run_env_value kernel_image)
    recorded_cause_window=$(run_env_value wake_cause_window_us)

    # v13 结果会记录本轮实际使用的 kernel。若该路径仍存在，优先复用它；
    # v12 及更早结果没有此字段，此时沿用调用者传入的 KERNEL_IMAGE。
    if [[ -n $recorded_kernel_image && -r $recorded_kernel_image ]]; then
        KERNEL_IMAGE=$recorded_kernel_image
    fi
    if [[ $recorded_cause_window =~ ^[1-9][0-9]*$ ]]; then
        WAKE_CAUSE_WINDOW_US=$recorded_cause_window
    fi

    [[ $EXPERIMENT_MODE == n1 || $EXPERIMENT_MODE == n5 || \
       $EXPERIMENT_MODE == n5_fifo ]] || \
        die "run.env 中 mode 无效"
    [[ $ROUND_ID =~ ^[0-9]+$ ]] || die "run.env 中 round 无效"
    [[ $TARGET_VCPU_TID =~ ^[0-9]+$ ]] || die "run.env 中 target_vcpu_tid 无效"
    [[ ${VM_PROCESS_PID[0]} =~ ^[0-9]+$ ]] || \
        die "run.env 中 target_firecracker_pid 无效"
    [[ $HOUSEKEEPING_CPU =~ ^[0-9]+$ ]] || \
        die "run.env 中 housekeeping_cpu 无效"
    [[ -n $WINDOW_START_TIME && -n $WINDOW_END_TIME ]] || \
        die "run.env 中缺少采集窗口时间"
    [[ -r $KERNEL_IMAGE ]] || \
        die "重新分析需要 guest kernel；请通过 KERNEL_IMAGE 指定实际路径"

    for command in perf awk taskset grep sed tail tee cp; do
        command -v "$command" >/dev/null || die "缺少命令: $command"
    done

    log "脚本版本=$SCRIPT_VERSION path=$(readlink -f "$0")"
    log "仅重新分析已有数据，不会启动 VM: $RUN_DIR"

    # perf.data 是不可替代的原始记录，分析器从不修改它。对可能被 v16
    # 重写的派生 CSV 先做一次只读基线备份，重复 analyze 不会覆盖该备份。
    for derived_file in \
        summary.csv \
        summary.txt \
        switch_out_events.csv \
        wakeup_cause_summary.csv \
        perf-event-counts.txt
    do
        backup_file="$RUN_DIR/${derived_file}.before-v16"
        if [[ -e $RUN_DIR/$derived_file && ! -e $backup_file ]]; then
            cp -a -- "$RUN_DIR/$derived_file" "$backup_file"
        fi
    done

    analyze_perf_data
    log "重新分析完成 summary=$RUN_DIR/summary.csv"
}

# 从 summary.csv 取 target 墙钟耗时 wall_s（= GO->DONE，即"action 总耗时"）。
# 单参数：打印 workload/round/wall_s。
# 双参数：第一参数为 cluster 噪声结果，第二参数为 baseline 结果，输出一行
#         baseline_wall_s / cluster_noise_wall_s / delta / delta_pct，即
#         你要在结果表里增加的那一列"cluster 噪声下的耗时"。
walltime() {
    [[ $# -ge 1 && $# -le 2 ]] || { die "用法: $0 walltime <summary.csv> [baseline_summary.csv]"; }
    local noisy=$1
    [[ -r $noisy ]] || die "summary.csv 不可读: $noisy"
    local n_wl n_rd n_ws
    read -r n_wl n_rd n_ws < <(awk -F, 'NR==2{print $2,$3,$4}' "$noisy")
    [[ -n ${n_ws:-} ]] || die "无法从 $noisy 读取 wall_s（确认该文件已跑完 analyze）"

    if [[ $# -eq 1 ]]; then
        printf 'workload=%s round=%s wall_s=%s\n' "$n_wl" "$n_rd" "$n_ws"
        return
    fi

    local base=$2
    [[ -r $base ]] || die "baseline summary.csv 不可读: $base"
    local b_wl b_rd b_ws
    read -r b_wl b_rd b_ws < <(awk -F, 'NR==2{print $2,$3,$4}' "$base")
    [[ -n ${b_ws:-} ]] || die "无法从 $base 读取 wall_s"
    [[ $b_wl == "$n_wl" && $b_rd == "$n_rd" ]] || \
        die "baseline 与噪声结果 workload/round 不一致: $b_wl/$b_rd vs $n_wl/$n_rd"

    local delta pct
    delta=$(awk -v n="$n_ws" -v b="$b_ws" 'BEGIN{printf "%.6f", n-b}')
    pct=$(awk -v n="$n_ws" -v b="$b_ws" 'BEGIN{printf "%.2f", (b+0>0?100*(n-b)/b:0)}')
    printf 'workload,round,baseline_wall_s,cluster_noise_wall_s,delta_s,delta_pct\n'
    printf '%s,%s,%s,%s,%s,%s\n' "$n_wl" "$n_rd" "$b_ws" "$n_ws" "$delta" "$pct"
}

main() {
    local command=${1:-help}
    [[ $# -eq 0 ]] || shift

    case $command in
        run)
            run_experiment "$@"
            ;;
        compare)
            [[ $# -eq 2 || $# -eq 3 ]] || { usage; return 2; }
            compare_runs "$1" "$2" "${3:-$(dirname "$2")/comparison.csv}"
            ;;
        walltime)
            walltime "$@"
            ;;
        analyze)
            analyze_existing_run "$@"
            ;;
        help|-h|--help)
            usage
            ;;
        *)
            usage >&2
            return 2
            ;;
    esac
}

main "$@"
