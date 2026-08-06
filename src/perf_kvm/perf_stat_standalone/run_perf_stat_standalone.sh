#!/usr/bin/env bash
# run_perf_stat_standalone.sh
# 完全独立脚本：直接 firecracker 二进制 + ext4 镜像启动 VM，
# 用 perf stat task-clock + /proc/<tid>/stat 两种方法测 target vCPU 的 oncpu time。
# 不依赖 v17 脚本，代码自包含。
#
# 用法:
#   sudo ./run_perf_stat_standalone.sh <workload> [mode] [round]
#   mode: n1(单VM) 或 n5(target+3background超分)，默认 n1
#
# 环境变量:
#   SCHED_FIFO=1               启用 SCHED_FIFO/50 (默认 0=CFS)
#   CLUSTER_NOISE_CPUS=96,...  启用 cluster noise (默认空=不启用)
#   CLUSTER_NOISE_WORKLOAD     noise VM 跑的 workload (默认 joke2k__faker-2007)
#   CLUSTER_NOISE_WARMUP       noise 预热秒数 (默认 10)
#   TARGET_CPU=102 HOUSEKEEPING_CPU=112
#   FIRECRACKER_BIN=/opt/kata/bin/firecracker
#   KERNEL_IMAGE=$PERF_KVM_DIR/ub_latency/vmlinux-fc-arm64
#   IMAGE_DIR=$PERF_KVM_DIR/ub_latency/ext4
#
# 示例:
#   sudo ./run_perf_stat_standalone.sh faker n5                         # CFS 超分
#   sudo SCHED_FIFO=1 ./run_perf_stat_standalone.sh faker n5            # FIFO 超分
#   sudo CLUSTER_NOISE_CPUS=96,98,100,104,106,108,110 \
#     SCHED_FIFO=1 ./run_perf_stat_standalone.sh faker n5               # FIFO + noise
#   sudo ./run_perf_stat_standalone.sh faker n1                         # CFS 单VM

set -Eeuo pipefail
export LC_ALL=C

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PERF_KVM_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ============================ 配置 ============================================
FIRECRACKER_BIN=${FIRECRACKER_BIN:-/opt/kata/bin/firecracker}
KERNEL_IMAGE=${KERNEL_IMAGE:-"$PERF_KVM_DIR/ub_latency/vmlinux-fc-arm64"}
IMAGE_DIR=${IMAGE_DIR:-"$PERF_KVM_DIR/ub_latency/ext4"}
RESULTS_DIR=${RESULTS_DIR:-"$PERF_KVM_DIR/results_perf_stat"}

TARGET_CPU=${TARGET_CPU:-102}
HOUSEKEEPING_CPU=${HOUSEKEEPING_CPU:-112}
MEM_MIB=${MEM_MIB:-1024}
READY_TIMEOUT=${READY_TIMEOUT:-120}
TARGET_TIMEOUT=${TARGET_TIMEOUT:-600}

CLUSTER_NOISE_CPUS=${CLUSTER_NOISE_CPUS:-}
CLUSTER_NOISE_WORKLOAD=${CLUSTER_NOISE_WORKLOAD:-joke2k__faker-2007}
CLUSTER_NOISE_WARMUP=${CLUSTER_NOISE_WARMUP:-10}

# workload 表: name|ext4|repo|commit|replay
WORKLOAD_TABLE=(
    "SpikeInterface__spikeinterface-1057|base-spikeinterface.ext4|/workspace/SpikeInterface__spikeinterface__0.96|7268ab900443ca3f0239de3007352d05f2d7d875|/generated_replay.sh"
    "12rambau__sepal_ui-747|base-12rambau.ext4|/workspace/12rambau__sepal_ui__2.15|a683a7665a9710acd5ca939308e18539e92014b7|/generated_replay.sh"
    "abhinavsingh__proxy.py-740|base-abhinavsingh.ext4|/workspace/abhinavsingh__proxy.py__2.3|8052c907e8ed7bd889a13c8029a657675d6fd13a|/generated_replay.sh"
    "mathandy__svgpathtools-170|base-mathandy.ext4|/workspace/mathandy__svgpathtools__1.4|c84c897bf2121ed86ceed45b4e027785351c2fd5|/generated_replay.sh"
    "joke2k__faker-2007|base-joke2k.ext4|/workspace/joke2k__faker__24.2|250fa19baf01aa2289afe44b07225f785cf536c5|/generated_replay.sh"
)

# ============================ 参数解析 ========================================
TARGET_WORKLOAD=${1:-}
MODE=${2:-n1}
ROUND_ID=${3:-1}

log() { printf '[perf-stat] %s\n' "$*"; }
die() { printf '[perf-stat] ERROR: %s\n' "$*" >&2; exit 1; }

[[ -n $TARGET_WORKLOAD ]] || { echo "用法: $0 <workload> [n1|n5] [round]"; exit 1; }
[[ $MODE == n1 || $MODE == n5 ]] || die "mode 必须是 n1 或 n5"
[[ $(id -u) -eq 0 ]] || die "需要 root"
[[ -x $FIRECRACKER_BIN ]] || die "firecracker 不存在: $FIRECRACKER_BIN"
[[ -f $KERNEL_IMAGE ]] || die "kernel 不存在: $KERNEL_IMAGE"

# 解析 workload 表
WL_FOUND=0
for entry in "${WORKLOAD_TABLE[@]}"; do
    IFS='|' read -r name ext4 repo commit replay <<< "$entry"
    if [[ $name == "$TARGET_WORKLOAD" ]]; then
        WL_FOUND=1; WL_NAME=$name; WL_EXT4=$ext4; WL_REPO=$repo; WL_COMMIT=$commit; WL_REPLAY=$replay
        break
    fi
done
[[ $WL_FOUND == 1 ]] || die "workload 不在表中: $TARGET_WORKLOAD"
ROOTFS_BASE="$IMAGE_DIR/$WL_EXT4"
[[ -f $ROOTFS_BASE ]] || die "ext4 镜像不存在: $ROOTFS_BASE"

# cgroup v2 + RT_GROUP_SCHED workaround (FIFO 模式需要)
if [[ -w /sys/fs/cgroup/cgroup.procs ]]; then
    echo $$ > /sys/fs/cgroup/cgroup.procs 2>/dev/null || true
fi

# ============================ 工具函数 ========================================
CLK_TCK=$(getconf CLK_TCK)

read_utime_stime() {
    local line fields
    line=$(cat /proc/$1/stat 2>/dev/null) || return 1
    fields="${line##*)}"
    local arr
    read -ra arr <<< "$fields"
    echo "${arr[11]} ${arr[12]}"
}

wait_for_marker() {
    local logf=$1 marker=$2 pid=$3 timeout=$4
    local deadline=$((SECONDS + timeout))
    while ((SECONDS <= deadline)); do
        grep -aFq "$marker" "$logf" 2>/dev/null && return 0
        kill -0 "$pid" 2>/dev/null || return 1
        sleep 0.02
    done
    return 1
}

find_vcpu_tid() {
    local fc_pid=$1 task_dir
    local deadline=$((SECONDS + READY_TIMEOUT))
    while ((SECONDS <= deadline)); do
        for task_dir in /proc/"$fc_pid"/task/*; do
            [[ -r $task_dir/comm ]] || continue
            if [[ $(<"$task_dir/comm") == "fc_vcpu 0" ]]; then
                basename "$task_dir"
                return 0
            fi
        done
        sleep 0.1
    done
    return 1
}

# ============================ guest init 脚本 ================================
generate_guest_init() {
    cat >"$1" <<'GUEST_INIT'
#!/bin/bash
set +u
mount -t proc proc /proc 2>/dev/null || true
mount -t sysfs sysfs /sys 2>/dev/null || true
mount -t devtmpfs devtmpfs /dev 2>/dev/null || true
mkdir -p /dev/pts /run /tmp
mount -t devpts devpts /dev/pts 2>/dev/null || true
exec </dev/ttyS0 >/dev/ttyS0 2>&1

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

fail() {
    echo "FC_ERROR role=${ROLE:-unknown} name=${NAME:-unknown} message=$*"
    while true; do sleep 3600; done
}

[[ $ROLE == target || $ROLE == background ]] || fail invalid_role
[[ -d $REPO/.git ]] || fail "repo_not_found:$REPO"
[[ -f $REPLAY ]] || fail "replay_not_found:$REPLAY"

export HOME=/root USER=root LOGNAME=root SHELL=/bin/bash
export PATH=/opt/miniconda3/envs/testbed/bin:/opt/miniconda3/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PYTHONUNBUFFERED=1 PIP_BREAK_SYSTEM_PACKAGES=1
if [[ -f /opt/miniconda3/etc/profile.d/conda.sh ]]; then
    source /opt/miniconda3/etc/profile.d/conda.sh >/dev/null 2>&1 || true
    conda activate testbed >/dev/null 2>&1 || true
fi

reset_repo() { git -C "$REPO" reset --hard "$COMMIT" >/dev/null 2>&1; }
run_replay_silent() { (cd "$REPO" && /bin/bash "$REPLAY") </dev/null >/dev/null 2>&1; }

reset_repo || fail reset_failed
echo "FC_READY role=$ROLE name=$NAME"

IFS= read -r command
[[ $command == GO ]] || fail expected_GO

if [[ $ROLE == background ]]; then
    echo "FC_BACKGROUND_STARTED name=$NAME"
    while true; do
        run_replay_silent || true
        reset_repo || fail reset_failed
    done
fi

echo "FC_TARGET_BEGIN name=$NAME"
run_replay_silent
rc=$?
echo "FC_TARGET_DONE name=$NAME rc=$rc"
GUEST_INIT
}

# ============================ firecracker 配置 ================================
generate_fc_config() {
    local config_file=$1 rootfs=$2 boot_args=$3
    cat >"$config_file" <<EOF
{
  "boot-source": {
    "kernel_image_path": "$(readlink -f "$KERNEL_IMAGE")",
    "boot_args": "$boot_args"
  },
  "drives": [{
    "drive_id": "rootfs",
    "path_on_host": "$(readlink -f "$rootfs")",
    "is_root_device": true,
    "is_read_only": false
  }],
  "machine-config": {"vcpu_count": 1, "mem_size_mib": $MEM_MIB}
}
EOF
}

make_boot_args() {
    local role=$1 name=$2 repo=$3 commit=$4 replay=$5
    local args="keep_bootcon console=ttyS0 reboot=k panic=1 pci=off"
    args+=" root=/dev/vda rw rootwait init=/fc-exp-init.sh"
    args+=" fc_role=$role fc_name=$name fc_repo=$repo fc_commit=$commit fc_replay=$replay"
    printf '%s' "$args"
}

# ============================ VM 启动/停止 ====================================
declare -a VM_PIDS=() VM_ROOTFS=() VM_CONSOLE=() VM_INPUT_FD=()
declare -a VM_API_SOCK=()

launch_vm() {
    local vm_index=$1 role=$2 name=$3 repo=$4 commit=$5 replay=$6
    local cpu=${7:-$TARGET_CPU}
    local rootfs_base=${8:-$ROOTFS_BASE}
    local rootfs_copy config_file stdin_fifo console_log api_socket input_fd boot_args

    rootfs_copy="$RUN_DIR/work/vm${vm_index}_${name}.ext4"
    config_file="$RUN_DIR/vm${vm_index}_${name}.json"
    stdin_fifo="$RUN_DIR/work/vm${vm_index}.stdin"
    console_log="$RUN_DIR/vm${vm_index}_${name}.console.log"
    api_socket="/tmp/perf-stat-${$}-${vm_index}.sock"

    VM_ROOTFS[$vm_index]=$rootfs_copy
    VM_API_SOCK[$vm_index]=$api_socket
    VM_CONSOLE[$vm_index]=$console_log

    log "启动 VM[$vm_index] role=$role workload=$name cpu=$cpu"

    cp --reflink=auto --sparse=always "$rootfs_base" "$rootfs_copy"

    debugfs -w -R 'rm /fc-exp-init.sh' "$rootfs_copy" >>"$RUN_DIR/debugfs.log" 2>&1 || true
    debugfs -w -R "write $RUN_DIR/guest-init.sh /fc-exp-init.sh" "$rootfs_copy" >>"$RUN_DIR/debugfs.log" 2>&1
    debugfs -w -R 'set_inode_field /fc-exp-init.sh mode 0100755' "$rootfs_copy" >>"$RUN_DIR/debugfs.log" 2>&1
    debugfs -R 'stat /fc-exp-init.sh' "$rootfs_copy" 2>>"$RUN_DIR/debugfs.log" | grep -q 'Mode:.*0755' || die "guest init 注入失败"

    boot_args=$(make_boot_args "$role" "$name" "$repo" "$commit" "$replay")
    generate_fc_config "$config_file" "$rootfs_copy" "$boot_args"

    rm -f -- "$api_socket"
    mkfifo "$stdin_fifo"
    exec {input_fd}<>"$stdin_fifo"

    taskset -c "$cpu" "$FIRECRACKER_BIN" \
        --api-sock "$api_socket" --config-file "$config_file" \
        <&"$input_fd" >"$console_log" 2>&1 &
    local fc_pid=$!

    VM_PIDS[$vm_index]=$fc_pid
    VM_INPUT_FD[$vm_index]=$input_fd

    if ! wait_for_marker "$console_log" "FC_READY role=$role name=$name" "$fc_pid" "$READY_TIMEOUT"; then
        tail -50 "$console_log" >&2 || true
        die "VM[$vm_index] 未进入 READY: $name"
    fi

    taskset -a -pc "$cpu" "$fc_pid" >/dev/null
    chrt -a -o -p 0 "$fc_pid" >/dev/null

    log "VM[$vm_index] READY pid=$fc_pid role=$role cpu=$cpu"
}

send_go() {
    printf 'GO\n' >&"${VM_INPUT_FD[$1]}"
}

start_cluster_noise() {
    [[ -z $CLUSTER_NOISE_CPUS ]] && return 0

    local noise_found=0 noise_name noise_ext4 noise_repo noise_commit noise_replay
    for entry in "${WORKLOAD_TABLE[@]}"; do
        IFS='|' read -r name ext4 repo commit replay <<< "$entry"
        if [[ $name == "$CLUSTER_NOISE_WORKLOAD" ]]; then
            noise_found=1
            noise_name=$name; noise_ext4=$ext4; noise_repo=$repo
            noise_commit=$commit; noise_replay=$replay
            break
        fi
    done
    [[ $noise_found == 1 ]] || die "noise workload 不在表中: $CLUSTER_NOISE_WORKLOAD"

    local noise_rootfs="$IMAGE_DIR/$noise_ext4"
    [[ -f $noise_rootfs ]] || die "noise ext4 不存在: $noise_rootfs"

    local noise_cpus=()
    IFS=',' read -ra noise_cpus <<< "$CLUSTER_NOISE_CPUS"

    local idx=0 cpu
    for cpu in "${noise_cpus[@]}"; do
        idx=$((idx + 1))
        local vm_idx=$((100 + idx))
        launch_vm "$vm_idx" background "$noise_name" "$noise_repo" \
            "$noise_commit" "$noise_replay" "$cpu" "$noise_rootfs"
        send_go "$vm_idx"
        wait_for_marker "${VM_CONSOLE[$vm_idx]}" \
            "FC_BACKGROUND_STARTED name=$noise_name" \
            "${VM_PIDS[$vm_idx]}" "$READY_TIMEOUT" || \
            die "noise VM[$idx] 未启动: cpu=$cpu"
    done
    log "cluster noise 已就绪 count=$idx cpus=$CLUSTER_NOISE_CPUS"
}

stop_all_vms() {
    local pid
    for pid in "${VM_PIDS[@]:-}"; do
        [[ -n $pid ]] || continue
        kill -TERM "$pid" 2>/dev/null || true
    done
    sleep 0.5
    for pid in "${VM_PIDS[@]:-}"; do
        [[ -n $pid ]] || continue
        kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    done
}

cleanup() {
    trap - EXIT INT TERM
    stop_all_vms
    local fd
    for fd in "${VM_INPUT_FD[@]:-}"; do
        [[ -n $fd ]] && exec {fd}>&- 2>/dev/null || true
    done
    for sock in "${VM_API_SOCK[@]:-}"; do
        [[ -n $sock ]] && rm -f -- "$sock" 2>/dev/null || true
    done
}

# ============================ 主流程 ==========================================
RUN_DIR="$RESULTS_DIR/$(date +%Y%m%d_%H%M%S)_${MODE}_r${ROUND_ID}_${WL_NAME}_$$"
mkdir -p "$RUN_DIR/work"
generate_guest_init "$RUN_DIR/guest-init.sh"
trap cleanup EXIT INT TERM

taskset -pc "$HOUSEKEEPING_CPU" $$ >/dev/null

log "实验 workload=$WL_NAME mode=$MODE round=$ROUND_ID"
log "CPU target=$TARGET_CPU housekeeping=$HOUSEKEEPING_CPU"

# 启动 background（n5 模式: target + 3 background）
if [[ $MODE == n5 ]]; then
    bg_count=0
    for entry in "${WORKLOAD_TABLE[@]}"; do
        IFS='|' read -r name ext4 repo commit replay <<< "$entry"
        [[ $name == "$WL_NAME" ]] && continue
        (( bg_count >= 3 )) && break
        bg_count=$((bg_count + 1))
        launch_vm "$bg_count" background "$name" "$repo" "$commit" "$replay"
        send_go "$bg_count"
        wait_for_marker "${VM_CONSOLE[$bg_count]}" "FC_BACKGROUND_STARTED name=$name" "${VM_PIDS[$bg_count]}" "$READY_TIMEOUT" || die "background 未启动: $name"
    done
    log "background 预热 10s"
    sleep 10
fi

# 启动 cluster noise（邻近核 L3 干扰）
if [[ -n $CLUSTER_NOISE_CPUS ]]; then
    start_cluster_noise
    log "cluster noise 预热 ${CLUSTER_NOISE_WARMUP}s"
    sleep "$CLUSTER_NOISE_WARMUP"
fi

# 启动 target
launch_vm 0 target "$WL_NAME" "$WL_REPO" "$WL_COMMIT" "$WL_REPLAY"
TARGET_TID=$(find_vcpu_tid "${VM_PIDS[0]}") || die "找不到 fc_vcpu 0"
log "target vcpu tid=$TARGET_TID"

# FIFO 模式: chrt SCHED_FIFO 50
if [[ ${SCHED_FIFO:-0} == 1 ]]; then
    chrt -f -p 50 "$TARGET_TID" || die "chrt SCHED_FIFO 失败"
    log "target 设置 SCHED_FIFO/50"
fi

# perf stat + /proc/pid/stat 采集
PERF_OUT="$RUN_DIR/perf_stat.txt"
PERF_STDOUT="$RUN_DIR/perf_stdout.log"

init_str=$(read_utime_stime "$TARGET_TID") || init_str="0 0"
INIT_UTIME=${init_str%% *}
INIT_STIME=${init_str##* }
log "init utime=$INIT_UTIME stime=$INIT_STIME clk_tck=$CLK_TCK"

log "启动 perf stat task-clock"
perf stat -t "$TARGET_TID" -e task-clock,cpu-clock \
    -o "$PERF_OUT" >"$PERF_STDOUT" 2>&1 &
PERF_PID=$!
sleep 1
kill -0 "$PERF_PID" 2>/dev/null || { cat "$PERF_STDOUT" >&2; die "perf stat 启动失败"; }

# GO → 等 DONE
WALL_START=$(date +%s.%N)
send_go 0
log "target replay 已开始"

wait_for_marker "${VM_CONSOLE[0]}" "FC_TARGET_DONE name=$WL_NAME" "${VM_PIDS[0]}" "$TARGET_TIMEOUT" || die "target 超时"
WALL_END=$(date +%s.%N)

TARGET_RC=$(grep -F "FC_TARGET_DONE name=$WL_NAME" "${VM_CONSOLE[0]}" | tail -1 | sed -n 's/.* rc=\([0-9]*\).*/\1/p')

# 停 perf stat + 读最终 utime/stime
kill -INT "$PERF_PID" 2>/dev/null || true
sleep 1
kill -0 "$PERF_PID" 2>/dev/null && kill -TERM "$PERF_PID" 2>/dev/null || true
wait "$PERF_PID" 2>/dev/null || true

fin_str=$(read_utime_stime "$TARGET_TID" 2>/dev/null) || fin_str="$init_str"
FINAL_UTIME=${fin_str%% *}
FINAL_STIME=${fin_str##* }
log "final utime=$FINAL_UTIME stime=$FINAL_STIME"

# 计算结果
WALL_SEC=$(python3 -c "print(f'{$WALL_END - $WALL_START:.9f}')")

TASK_CLOCK_MS=$(awk '/task-clock/{for(i=1;i<=NF;i++) if($i ~ /^[0-9.,]+$/){gsub(/,/,"",$i); print $i; exit}}' "$PERF_OUT" 2>/dev/null || echo "0")
ONCPU_TC=$(python3 -c "print(f'{float(\"$TASK_CLOCK_MS\")/1000:.9f}')")

CPU_CLOCK_MS=$(awk '/cpu-clock/{for(i=1;i<=NF;i++) if($i ~ /^[0-9.,]+$/){gsub(/,/,"",$i); print $i; exit}}' "$PERF_OUT" 2>/dev/null || echo "0")
ONCPU_CPU_CLOCK=$(python3 -c "print(f'{float(\"$CPU_CLOCK_MS\")/1000:.9f}')")

ONCPU_US=$(python3 -c "
iu=$INIT_UTIME; fu=$FINAL_UTIME; is=$INIT_STIME; fs=$FINAL_STIME; clk=$CLK_TCK
print(f'{((fu-iu)+(fs-is))/clk:.9f}')
")

ONCPU_PCT=$(python3 -c "
w=float('$WALL_SEC'); tc=float('$ONCPU_TC')
print(f'{tc/w*100:.2f}' if w>0 else 'N/A')
")

# 输出
{
    echo "============================================"
    echo "  perf stat oncpu 采集结果"
    echo "============================================"
    echo ""
    echo "workload              = $WL_NAME"
    echo "mode                  = $MODE"
    echo "round                 = $ROUND_ID"
    echo "target_tid            = $TARGET_TID"
    echo "target_rc             = ${TARGET_RC:-unknown}"
    echo "sched_fifo            = ${SCHED_FIFO:-0}"
    echo "cluster_noise_cpus    = $CLUSTER_NOISE_CPUS"
    echo "cluster_noise_workload= $CLUSTER_NOISE_WORKLOAD"
    echo ""
    echo "--- on-CPU time (3 种方法) ---"
    echo "  perf_stat_task_clock_s = $ONCPU_TC"
    echo "  perf_stat_cpu_clock_s  = $ONCPU_CPU_CLOCK"
    echo "  proc_pid_stat_s         = $ONCPU_US"
    echo ""
    echo "--- 墙钟 ---"
    echo "  wall_s                 = $WALL_SEC"
    echo "  oncpu_pct (tc/wall)    = $ONCPU_PCT%"
    echo ""
    echo "--- 原始 ---"
    echo "  clk_tck        = $CLK_TCK"
    echo "  init_utime     = $INIT_UTIME"
    echo "  init_stime     = $INIT_STIME"
    echo "  final_utime    = $FINAL_UTIME"
    echo "  final_stime    = $FINAL_STIME"
    echo "  task_clock_ms  = $TASK_CLOCK_MS"
    echo "  cpu_clock_ms   = $CPU_CLOCK_MS"
} | tee "$RUN_DIR/summary.txt"

{
    echo "workload=$WL_NAME"
    echo "mode=$MODE"
    echo "round=$ROUND_ID"
    echo "sched_fifo=${SCHED_FIFO:-0}"
    echo "cluster_noise_cpus=$CLUSTER_NOISE_CPUS"
    echo "cluster_noise_workload=$CLUSTER_NOISE_WORKLOAD"
    echo "wall_s=$WALL_SEC"
    echo "oncpu_task_clock_s=$ONCPU_TC"
    echo "oncpu_cpu_clock_s=$ONCPU_CPU_CLOCK"
    echo "oncpu_proc_stat_s=$ONCPU_US"
    echo "oncpu_pct=$ONCPU_PCT"
    echo "target_tid=$TARGET_TID"
} > "$RUN_DIR/result.env"

log "完成 run_dir=$RUN_DIR"

printf 'PERF_STAT_RESULT,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "$WL_NAME" "$MODE" "$ROUND_ID" "${SCHED_FIFO:-0}" \
    "${CLUSTER_NOISE_CPUS:+1}" \
    "$WALL_SEC" "$ONCPU_TC" "$ONCPU_CPU_CLOCK" "$ONCPU_US"
