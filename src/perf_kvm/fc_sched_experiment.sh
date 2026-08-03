#!/usr/bin/env bash
# ==============================================================================
# fc_sched_experiment.sh
# 直接使用 Firecracker 的 N=1 / N=5 单核调度实验脚本（单文件版本）
# ==============================================================================
#
# 一、实验要回答的问题
# ------------------------------------------------------------------------------
# 在 N=5 单核超分时，被观测 Firecracker vCPU 的“主动调出”为什么比 N=1 多：
#
#   1. 多出来的主动调出有多少次；
#   2. 其中多少由 guest 执行 WFI/WFE 引起；
#   3. 不能归因于 WFI/WFE 的 other 类型有多少；
#   4. WFI、WFE、other 分别占新增主动调出的比例。
#
# 二、两种实验模式
# ------------------------------------------------------------------------------
# N=1：只启动被观测 microVM，被观测 workload 只执行一次。
#
# N=5：先启动 4 台 background microVM，每台 background 在 guest 内循环
#      replay；预热完成后再启动 target，target workload 只执行一次。
#      5 个完整 Firecracker 进程的全部宿主机线程共享 TARGET_CPU。
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
#
# 因此 Firecracker boot、guest 初始化、git reset，以及 perf 初始化期间的
# READY 等待不会进入 perf.data。enable ack 到发送 GO 之间只保留记录起点和
# 写入串口 FIFO 两个必要操作，既把边界压到最小，也不会漏掉 replay 开头。
#
# 五、主要输出
# ------------------------------------------------------------------------------
#   summary.csv             调度次数、主动/被动、时间片、gap、onCPU 等汇总
#   switch_out_events.csv   每次 target vCPU 调出及其时间片、后续 gap
#   perf.data               perf kvm stat record 产生的原始数据
#   perf.txt                perf script 转换后的文本
#   kvm-stat-report.txt     perf kvm stat report 的 target VM-exit 统计
#   threads.csv             各 Firecracker 宿主机线程及 TID
#   *.console.log           各 microVM 的串口日志
#
# ==============================================================================

set -Eeuo pipefail
export LC_ALL=C
shopt -u varredir_close 2>/dev/null || true

# 每次启动都会打印这个版本号和脚本的绝对路径。这样服务器上即使同时留有
# 多个同名副本，也能从实验日志直接确认真正执行的是哪一版。
SCRIPT_VERSION="2026-07-23-v13"

readonly SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

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
WINDOW_START_TIME=
WINDOW_END_TIME=
TARGET_EXIT_CODE=

log() { printf '[fc-exp] %s\n' "$*"; }
die() { printf '[fc-exp] ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<EOF
运行一个实验 case：
  sudo env TARGET_CPU=102 HOUSEKEEPING_CPU=0 \\
    $0 run <n1|n5> <target-workload> <round>

默认资源位置（均相对于本脚本）：
  kernel：$SCRIPT_DIR/vmlinux-fc-arm64
  ext4：  $SCRIPT_DIR/ext4/base-*.ext4
  如文件位于其他目录，可用 KERNEL_IMAGE 和 IMAGE_DIR 环境变量覆盖。

参数含义：
  n1 / n5          单 VM，或五台完整 VM 共享一个宿主机 CPU
  target-workload  workload_table 中被观测任务的名称
  round            重复实验的轮次编号，例如 1、2、3

比较同一个 target、同一个 round 的 N=1/N=5：
  $0 compare <n1-summary.csv> <n5-summary.csv> [comparison.csv]

只重新分析已经采集完成的结果，不重新启动 VM：
  sudo env KERNEL_IMAGE=/实际路径/vmlinux-fc-arm64 \\
    $0 analyze <run_dir>

新版本生成的 run.env 会记录 kernel_image，后续重新分析时通常不必再次指定。
旧版本结果没有该字段，且 kernel 不在脚本默认位置时，需要显式传 KERNEL_IMAGE。
EOF
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

# 决定本轮 VM 组成：target 固定为下标 0，其余四项在 N=5 中作为背景。
select_case_workloads() {
    local name
    [[ -n ${ROOTFS_OF[$TARGET_WORKLOAD]+yes} ]] || \
        die "workload 配置表中没有 target: $TARGET_WORKLOAD"
    CASE_WORKLOADS=("$TARGET_WORKLOAD")
    if [[ $EXPERIMENT_MODE == n5 ]]; then
        for name in "${ALL_WORKLOADS[@]}"; do
            [[ $name != "$TARGET_WORKLOAD" ]] && CASE_WORKLOADS+=("$name")
        done
        ((${#CASE_WORKLOADS[@]} == 5)) || die "N=5 要求 workload_table 中恰好有 5 项"
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
    local command event name tracefs perf_record_help
    [[ $(id -u) -eq 0 ]] || die "采集必须以 root 运行"
    [[ -x $FIRECRACKER_BIN ]] || die "Firecracker 不存在或不可执行: $FIRECRACKER_BIN"
    [[ -f $KERNEL_IMAGE ]] || die "guest kernel 不存在: $KERNEL_IMAGE"
    [[ -r /dev/kvm && -w /dev/kvm ]] || die "/dev/kvm 不可读写"
    [[ $TARGET_CPU =~ ^[0-9]+$ && $HOUSEKEEPING_CPU =~ ^[0-9]+$ ]] || \
        die "TARGET_CPU 和 HOUSEKEEPING_CPU 必须是整数"
    [[ $TARGET_CPU != "$HOUSEKEEPING_CPU" ]] || die "实验核和 housekeeping 核不能相同"
    [[ -d /sys/devices/system/cpu/cpu$TARGET_CPU ]] || die "CPU $TARGET_CPU 不存在"
    [[ -d /sys/devices/system/cpu/cpu$HOUSEKEEPING_CPU ]] || die "CPU $HOUSEKEEPING_CPU 不存在"

    for command in perf awk debugfs taskset chrt renice grep sed date cp mkfifo \
                   readlink tail tee sleep; do
        command -v "$command" >/dev/null || die "缺少命令: $command"
    done

    # 本实验依赖 perf 的运行期控制接口。旧版 perf 没有 --control 时，若继续
    # 执行就只能把 READY 等待也录进 perf.data，因此在创建 VM 前明确失败。
    perf_record_help=$(perf record -h 2>&1 || true)
    [[ $perf_record_help == *--control* && $perf_record_help == *--delay* ]] || \
        die "当前 perf 不支持 --control/--delay=-1，请升级 perf 后再运行"

    tracefs=$(find_tracepoint_directory) || die "未找到 tracefs events 目录"
    for event in sched/sched_switch kvm/kvm_entry kvm/kvm_exit kvm/kvm_wfx_arm64; do
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

# 出错后不直接退出 PID 1，避免内核 panic 淹没真正错误；串口会保留
# FC_ERROR，宿主机最终因等待 READY 超时而停止本轮实验。
fail() {
    echo "FC_ERROR role=${ROLE:-unknown} name=${NAME:-unknown} message=$*"
    while true; do sleep 3600; done
}

[[ $ROLE == target || $ROLE == background ]] || fail invalid_role
[[ -d $REPO/.git ]] || fail "repo_not_found:$REPO"
[[ -f $REPLAY ]] || fail "replay_not_found:$REPLAY"

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
run_replay() { (cd "$REPO" && /bin/bash "$REPLAY") </dev/null >/dev/null 2>&1; }

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
        run_replay || true
        reset_repo || fail reset_failed
    done
fi

# target 只执行一次。BEGIN/DONE 是宿主机确定采集窗口和返回码的标记。
echo "FC_TARGET_BEGIN name=$NAME"
run_replay
rc=$?
echo "FC_TARGET_DONE name=$NAME rc=$rc"

# DONE 后阻塞，不再执行第二轮 replay。宿主机看到 DONE 后立即停止 perf，
# 然后终止 target 和四个 background Firecracker 进程。
IFS= read -r _ || true
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

# 无论正常结束、命令失败还是用户按 Ctrl-C，都会进入这里。
# 清理顺序是：停止采集 -> 停止 VM -> 关闭 FIFO -> 删除临时文件。
cleanup_generated_resources() {
    local original_exit_code=$? path file_descriptor
    trap - EXIT INT TERM

    stop_perf_recording
    stop_all_vms

    # 每个 FIFO 都被宿主机以“读写”方式打开；关闭相应 FD 后才可安全删除。
    for file_descriptor in "${VM_INPUT_FD[@]:-}"; do
        if [[ $file_descriptor =~ ^[0-9]+$ ]]; then
            exec {file_descriptor}>&- || true
        fi
    done

    for path in "${VM_API_SOCKET[@]:-}" "${VM_STDIN_FIFO[@]:-}"; do
        [[ -n $path ]] && rm -f -- "$path"
    done

    # 只删除本轮 RUN_DIR/work 下由脚本复制出的 rootfs，绝不删除 base ext4。
    # 调试启动问题时可设置 KEEP_DISKS=1 保留这些副本。
    if [[ $KEEP_DISKS == 0 && -n $RUN_DIR ]]; then
        for path in "${VM_ROOTFS[@]:-}"; do
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
        grep -Fq "$expected_marker" "$console_log" 2>/dev/null && return 0
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

# 向指定 VM 的串口发送 GO，解除 guest init 的 READY/GO 屏障。
send_guest_go() {
    local input_fd=${VM_INPUT_FD[$1]}
    printf 'GO\n' >&"$input_fd"
}

# ============================= perf 采集与分析 ================================

# 启动 perf kvm，只采 TARGET_CPU，但暂时不启用事件。
#
# perf kvm stat record 会根据宿主机架构自动加入 KVM entry/exit tracepoint，
# 这些事件供后续 perf kvm stat report 统计 VM-exit 原因与处理时间。
#
# 我们另外加入两个事件：
#   1. sched_switch：计算调度次数、主动/被动调出、时间片、gap、onCPU；
#   2. kvm_wfx_arm64：判断一次主动调出之前是否执行了 WFI/WFE。
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
        -e kvm:kvm_wfx_arm64 --filter "common_pid == $TARGET_VCPU_TID" \
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
    [[ ${PERF_EVENTS_ENABLED:-0} == 1 ]] || return 0

    if ! send_perf_control_command disable; then
        PERF_EVENTS_ENABLED=0
        cat "$RUN_DIR/perf-kvm-record.log" >&2 || true
        die "perf disable 未收到 ack"
    fi
    PERF_EVENTS_ENABLED=0
    log "perf 事件已禁用"
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
    local kvm_report_wfx_count

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
    } >"$RUN_DIR/perf-event-counts.txt"

    (( sched_line_count > 0 )) || \
        die "perf.txt 中没有 sched_switch，无法统计调度指标"
    (( kvm_entry_count > 0 && kvm_exit_count > 0 )) || \
        die "perf.txt 中没有完整 KVM entry/exit，无法可靠归因主动调出"
    if (( kvm_wfx_count != kvm_report_wfx_count )); then
        die "WFx 数量不一致：perf.txt=$kvm_wfx_count，KVM报告=$kvm_report_wfx_count"
    fi

    awk -v target_tid="$TARGET_VCPU_TID" \
        -v wall_start="$WINDOW_START_TIME" -v wall_end="$WINDOW_END_TIME" \
        -v experiment_mode="$EXPERIMENT_MODE" -v target="$TARGET_WORKLOAD" \
        -v round_id="$ROUND_ID" -v summary_file="$RUN_DIR/summary.csv" \
        -v event_file="$RUN_DIR/switch_out_events.csv" '
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

        # 从 sched_switch trace 文本中读取 prev_pid、prev_state、next_pid 等字段。
        function trace_field(line, key, value) {
            value=line
            sub("^.*" key "=","",value)
            sub(/[[:space:]].*$/,"",value)
            return value
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

            # 一次 WFI/WFE 应在 vCPU 真正睡眠前与后续 sched_switch 配对。
            # 若已经重新进入 guest 仍未发生主动调出，说明旧 WFX 不能再用于
            # 解释后面的 switch；把它记入 unmatched_wfx 作为数据质量提示。
            if (index($0,"kvm:kvm_entry:") || index($0,"kvm:kvm_entry_v2:")) {
                if (sample_tid($0) != target_tid+0) next
                if (pending_wfx!="") unmatched_wfx++
                pending_wfx=""
                last_kvm_exit=""
                next
            }

            # 保存 target 最近一次 KVM exit 的原始上下文。它是 other 类型的
            # 人工排查线索，但不能仅凭某个 exit reason 判定主动调出。
            if (index($0,"kvm:kvm_exit:") || index($0,"kvm:kvm_exit_v2:")) {
                if (sample_tid($0) != target_tid+0) next
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
                    current_gap_ms=(timestamp-row_out_time[waiting_gap_row])*1000
                    if (current_gap_ms >= 0) {
                        gap_count++
                        gap_values[gap_count]=current_gap_ms
                        gap_sum_ms+=current_gap_ms
                        row_has_gap[waiting_gap_row]=1
                        row_next_in_time[waiting_gap_row]=timestamp
                        row_gap_ms[waiting_gap_row]=current_gap_ms
                    }
                    waiting_gap_row=0
                }
                last_switch_in_time=timestamp
            }
        }

        END {
            if (pending_wfx!="") unmatched_wfx++

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
            slice_avg_ms=(slice_count ? slice_sum_ms/slice_count : "")
            slice_p50_ms=percentile(slice_values,slice_count,0.50)
            slice_p99_ms=percentile(slice_values,slice_count,0.99)
            gap_avg_ms=(gap_count ? gap_sum_ms/gap_count : "")
            gap_p50_ms=percentile(gap_values,gap_count,0.50)
            gap_p99_ms=percentile(gap_values,gap_count,0.99)
            oncpu_s=slice_sum_ms/1000

            wfi_percent=(voluntary_total ? \
                100*voluntary_by_reason["wfi"]/voluntary_total : 0)
            wfe_percent=(voluntary_total ? \
                100*voluntary_by_reason["wfe"]/voluntary_total : 0)
            other_percent=(voluntary_total ? \
                100*voluntary_by_reason["other"]/voluntary_total : 0)
            switch_out_total=voluntary_total+passive_total

            # 明细到 END 才写出，因为每次调出的 gap 要等后续调入事件才能获得。
            print "out_time,kind,subtype,prev_state,slice_ms,next_comm,next_pid," \
                  "last_kvm_exit,next_in_time,gap_ms" > event_file
            for (row_index=1; row_index<=switch_row_count; row_index++) {
                slice_text=(row_has_slice[row_index] ? \
                    sprintf("%.6f",row_slice_ms[row_index]) : "")
                next_in_text=(row_has_gap[row_index] ? \
                    sprintf("%.9f",row_next_in_time[row_index]) : "")
                gap_text=(row_has_gap[row_index] ? \
                    sprintf("%.6f",row_gap_ms[row_index]) : "")
                printf "%.9f,%s,%s,%s,%s,%s,%d,%s,%s,%s\n", \
                    row_out_time[row_index],row_kind[row_index],row_subtype[row_index], \
                    row_previous_state[row_index],slice_text, \
                    csv_quote(row_next_name[row_index]),row_next_pid[row_index], \
                    csv_quote(row_exit_context[row_index]),next_in_text,gap_text \
                    >> event_file
            }

            print "mode,target,round,wall_s,voluntary_total,voluntary_wfi,voluntary_wfe," \
                  "voluntary_other,passive_total,wfi_pct,wfe_pct,other_pct,unmatched_wfx," \
                  "switch_out_total,slice_count,slice_avg_ms,slice_p50_ms,slice_p99_ms," \
                  "gap_count,gap_avg_ms,gap_p50_ms,gap_p99_ms,oncpu_s," \
                  "unparsed_sched" > summary_file

            printf "%s,%s,%s,%.6f,%d,%d,%d,%d,%d,%.2f,%.2f,%.2f,%d,%d,%d," \
                   "%s,%s,%s,%d,%s,%s,%s,%.9f,%d\n", \
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

            printf "switch_out=%d, voluntary=%d (wfi=%d, wfe=%d, other=%d), " \
                   "passive=%d, slice_avg_ms=%s, gap_avg_ms=%s, oncpu_s=%.6f, " \
                   "unparsed_sched=%d\n", \
                switch_out_total,voluntary_total,voluntary_by_reason["wfi"], \
                voluntary_by_reason["wfe"],voluntary_by_reason["other"],passive_total, \
                (slice_count?sprintf("%.6f",slice_avg_ms):"NA"), \
                (gap_count?sprintf("%.6f",gap_avg_ms):"NA"),oncpu_s,unparsed_sched
        }
    ' "$RUN_DIR/perf.txt" | tee "$RUN_DIR/summary.txt"
}

# 对同一 target、同一轮次的 N=1 与 N=5 汇总做差。
# “share_of_extra”分母是 N5 主动调出数 - N1 主动调出数；例如 WFI 的
# share_of_extra=80%，表示新增主动调出中有 80% 可由新增 WFI 解释。
compare_runs() {
    local n1_summary=$1 n5_summary=$2 comparison_output=$3
    [[ -r $n1_summary && -r $n5_summary ]] || die "N=1 或 N=5 summary.csv 不可读"

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
            printf "%-18s n1=%-14s n5=%-14s delta=%-14s share=%s\n", \
                metric_name,n1_text,n5_text,delta_text, \
                (share_of_extra=="" ? "-" : share_of_extra "%")
        }

        END {
            # 防止误拿不同 workload、不同轮次或方向颠倒的两个文件比较。
            if (n1_column_count < 23 || n5_column_count < 23 || \
                n1_row[1]!="n1" || n5_row[1]!="n5" || \
                n1_row[2]!=n5_row[2] || n1_row[3]!=n5_row[3]) {
                print "ERROR: 必须提供当前脚本生成的同 target、同轮次 N=1/N=5 summary" \
                    > "/dev/stderr"
                exit 2
            }

            extra_voluntary=(n5_row[5]+0)-(n1_row[5]+0)
            print "metric,n1,n5,delta,share_of_extra_voluntary_pct" > output_file
            printf "target=%s round=%s extra_voluntary=%d\n", \
                n1_row[2],n1_row[3],extra_voluntary
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
            print "comparison_csv=" output_file
        }
    ' "$n1_summary" "$n5_summary"
}

# ================================ 主流程 =====================================

run_experiment() {
    # 第 1 步：解析并验证命令行。本脚本一次只运行一个 N=1 或 N=5 case。
    [[ $# -eq 3 ]] || { usage; return 2; }
    EXPERIMENT_MODE=$1
    TARGET_WORKLOAD=$2
    ROUND_ID=$3

    log "脚本版本=$SCRIPT_VERSION path=$(readlink -f "$0")"

    [[ $EXPERIMENT_MODE == n1 || $EXPERIMENT_MODE == n5 ]] || \
        die "实验模式必须是 n1 或 n5"
    [[ $ROUND_ID =~ ^[0-9]+$ ]] || die "round 必须是非负整数"
    [[ $KEEP_DISKS == 0 || $KEEP_DISKS == 1 ]] || die "KEEP_DISKS 只能是 0 或 1"
    [[ $PERF_CONTROL_TIMEOUT =~ ^[1-9][0-9]*$ ]] || \
        die "PERF_CONTROL_TIMEOUT 必须是正整数秒"

    load_workload_table
    select_case_workloads
    check_environment

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
    if [[ $EXPERIMENT_MODE == n5 ]]; then
        # 第 3 步（仅 N=5）：启动四台 background。
        # 四台都 READY 后再一起 GO；它们各自在同一 guest 内反复 replay。
        # 等预热结束才创建 target，避免把 background 的 boot/git reset 计入测量。
        log "开始启动 4 台 background VM"
        for ((vm_index=1; vm_index<5; vm_index++)); do
            launch_vm "$vm_index" background
        done
        for ((vm_index=1; vm_index<5; vm_index++)); do
            send_guest_go "$vm_index"
        done
        for ((vm_index=1; vm_index<5; vm_index++)); do
            wait_for_console_marker "${VM_CONSOLE_LOG[$vm_index]}" \
                "FC_BACKGROUND_STARTED name=${CASE_WORKLOADS[$vm_index]}" \
                "${VM_PROCESS_PID[$vm_index]}" "$READY_TIMEOUT" || \
                die "background 未开始循环: ${CASE_WORKLOADS[$vm_index]}"
        done
        log "background 已开始循环，预热 ${BACKGROUND_WARMUP}s"
        sleep "$BACKGROUND_WARMUP"
    fi

    # 第 4 步：启动 target。此时 target 只完成 boot/reset，停在 READY，
    # 所以查 TID、核验绑核和启动 perf 都不会漏掉 replay 的开头。
    log "开始启动被观测 target VM"
    launch_vm 0 target
    TARGET_VCPU_TID=$(find_target_vcpu_tid "${VM_PROCESS_PID[0]}") || \
        die "找不到 target 的 fc_vcpu 0 线程"
    log "被观测线程 target_vcpu_tid=$TARGET_VCPU_TID"

    # 保存足以复核本轮配置的元数据。threads.csv 则记录每台 FC 的全部线程。
    printf 'target_firecracker_pid=%s\ntarget_vcpu_tid=%s\n' \
        "${VM_PROCESS_PID[0]}" "$TARGET_VCPU_TID" >"$RUN_DIR/run.env"
    printf 'mode=%s\ntarget=%s\nround=%s\ntarget_cpu=%s\nhousekeeping_cpu=%s\n' \
        "$EXPERIMENT_MODE" "$TARGET_WORKLOAD" "$ROUND_ID" \
        "$TARGET_CPU" "$HOUSEKEEPING_CPU" >>"$RUN_DIR/run.env"
    printf 'perf_version=%s\nkernel_release=%s\nkernel_image=%s\n' \
        "$(perf --version)" "$(uname -r)" "$(readlink -f "$KERNEL_IMAGE")" \
        >>"$RUN_DIR/run.env"
    for ((vm_index=0; vm_index<${#CASE_WORKLOADS[@]}; vm_index++)); do
        printf 'vm_%s=%s\n' "$vm_index" "${CASE_WORKLOADS[$vm_index]}" >>"$RUN_DIR/run.env"
    done

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

    # 第 6 步：先让 perf 正常落盘，再停止所有 VM，最后生成明细和汇总。
    stop_perf_recording
    stop_all_vms
    analyze_perf_data

    log "实验完成 run_dir=$RUN_DIR"
    log "target 返回码=${TARGET_EXIT_CODE:-unknown}"
    [[ ${TARGET_EXIT_CODE:-1} == 0 ]]
}

# 对已有 run_dir 重新执行报告和 AWK 后处理，不启动 Firecracker，也不重新
# 采集 perf.data。这个入口主要用于升级分析逻辑后复用已有的原始数据。
analyze_existing_run() {
    local recorded_kernel_image

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

    # v13 结果会记录本轮实际使用的 kernel。若该路径仍存在，优先复用它；
    # v12 及更早结果没有此字段，此时沿用调用者传入的 KERNEL_IMAGE。
    if [[ -n $recorded_kernel_image && -r $recorded_kernel_image ]]; then
        KERNEL_IMAGE=$recorded_kernel_image
    fi

    [[ $EXPERIMENT_MODE == n1 || $EXPERIMENT_MODE == n5 ]] || \
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

    for command in perf awk taskset grep sed tail tee; do
        command -v "$command" >/dev/null || die "缺少命令: $command"
    done

    log "脚本版本=$SCRIPT_VERSION path=$(readlink -f "$0")"
    log "仅重新分析已有数据，不会启动 VM: $RUN_DIR"
    analyze_perf_data
    log "重新分析完成 summary=$RUN_DIR/summary.csv"
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
