#!/usr/bin/env bash
# run_perf_stat_oncpu.sh
# 独立脚本：source v17 复用 VM 启动/绑核/FIFO/cluster noise 函数，
# 但 perf 采集只用 perf stat task-clock + /proc/<tid>/stat utime/stime。
# 只有一个 perf 进程，不与 v17 的 perf kvm record 并行，零干扰。
#
# 用法:
#   sudo ./run_perf_stat_oncpu.sh <n5|n5_fifo> <workload> [round] [with_noise]
#   with_noise=1 启用 cluster noise，默认 0
#
# 示例:
#   sudo ./run_perf_stat_oncpu.sh n5 SpikeInterface__spikeinterface-1057 1 0
#   sudo CLUSTER_NOISE_CPUS=96,98,100,104,106,108,110 \
#     ./run_perf_stat_oncpu.sh n5_fifo joke2k__faker-2007 1 1

set -Eeuo pipefail
export LC_ALL=C

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
V17="$SCRIPT_DIR/fc_sched_experiment_v17.sh"

[[ -f "$V17" ]] || { echo "找不到 $V17" >&2; exit 1; }
[[ $# -ge 2 ]] || { echo "用法: $0 <n5|n5_fifo> <workload> [round] [with_noise]" >&2; exit 1; }

# source v17 复用所有函数（source guard 保证不执行 main）
source "$V17"

# ---- 参数 ----
EXPERIMENT_MODE=$1
TARGET_WORKLOAD=$2
ROUND_ID=${3:-1}
WITH_NOISE=${4:-0}

[[ $EXPERIMENT_MODE == n5 || $EXPERIMENT_MODE == n5_fifo ]] || die "mode 必须是 n5 或 n5_fifo"

# with_noise=1 时强制启用 cluster noise
if [[ $WITH_NOISE == 1 && -z ${CLUSTER_NOISE_CPUS:-} ]]; then
    die "with_noise=1 需要 CLUSTER_NOISE_CPUS 环境变量"
fi
if [[ $WITH_NOISE == 0 ]]; then
    CLUSTER_NOISE_CPUS=
fi

# ---- 初始化（复用 v17 函数）----
load_workload_table
select_case_workloads
check_environment
parse_cluster_noise_cpus

# ---- 创建 RUN_DIR ----
RUN_DIR="$RESULTS_DIR/$(date +%Y%m%d_%H%M%S)_xval_${EXPERIMENT_MODE}_r${ROUND_ID}_${TARGET_WORKLOAD}_$$"
mkdir -p "$RUN_DIR/work"
printf 'vm_index,workload,pid,tid,comm\n' >"$RUN_DIR/threads.csv"
write_guest_init "$RUN_DIR/guest-init.sh"
trap cleanup_generated_resources EXIT INT TERM
taskset -pc "$HOUSEKEEPING_CPU" $$ >/dev/null

log "xval 实验 mode=$EXPERIMENT_MODE target=$TARGET_WORKLOAD round=$ROUND_ID noise=$WITH_NOISE"
log "CPU Firecracker=$TARGET_CPU 脚本/perf=$HOUSEKEEPING_CPU"
log "本轮 VM: ${CASE_WORKLOADS[*]}"

# ---- 启动 background + cluster noise（复用 v17 逻辑）----
if is_five_vm_mode; then
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

    if is_cluster_noise_enabled; then
        start_cluster_noise
        log "cluster 噪声预热 ${CLUSTER_NOISE_WARMUP}s"
        sleep "$CLUSTER_NOISE_WARMUP"
    fi
fi

# ---- 启动 target ----
log "开始启动 target VM"
launch_vm 0 target
TARGET_VCPU_TID=$(find_target_vcpu_tid "${VM_PROCESS_PID[0]}") || \
    die "找不到 target fc_vcpu 0"
log "target_vcpu_tid=$TARGET_VCPU_TID"

configure_and_verify_thread_schedulers

# ---- perf stat + /proc/pid/stat 采集 ----
CLK_TCK=$(getconf CLK_TCK)

read_utime_stime() {
    local line fields
    line=$(cat /proc/$1/stat 2>/dev/null) || return 1
    fields="${line##*)}"
    local arr
    read -ra arr <<< "$fields"
    echo "${arr[11]} ${arr[12]}"
}

PERF_STAT_OUT="$RUN_DIR/xval_perf_stat.txt"
PERF_STDOUT="$RUN_DIR/xval_perf_stdout.log"

init_str=$(read_utime_stime "$TARGET_VCPU_TID") || init_str="0 0"
INIT_UTIME=${init_str%% *}
INIT_STIME=${init_str##* }
log "init utime=$INIT_UTIME stime=$INIT_STIME clk_tck=$CLK_TCK"

log "启动 perf stat task-clock tid=$TARGET_VCPU_TID"
perf stat -t "$TARGET_VCPU_TID" \
    -e task-clock,cpu-clock \
    -o "$PERF_STAT_OUT" >"$PERF_STDOUT" 2>&1 &
PERF_STAT_PID=$!
sleep 1
kill -0 "$PERF_STAT_PID" 2>/dev/null || { cat "$PERF_STDOUT" >&2; die "perf stat 启动失败"; }

# ---- GO → 等 DONE ----
WINDOW_START=$(date +%s.%N)
send_guest_go 0
log "target replay 已开始"

wait_for_console_marker "${VM_CONSOLE_LOG[0]}" \
    "FC_TARGET_DONE name=$TARGET_WORKLOAD" "${VM_PROCESS_PID[0]}" \
    "$TARGET_TIMEOUT" || die "target 超时或提前退出"
WINDOW_END=$(date +%s.%N)

TARGET_EXIT_CODE=$(grep -F "FC_TARGET_DONE name=$TARGET_WORKLOAD" \
    "${VM_CONSOLE_LOG[0]}" | tail -1 | \
    sed -n 's/.* rc=\([0-9][0-9]*\).*/\1/p')

# ---- 停 perf stat + 读最终 utime/stime ----
kill -INT "$PERF_STAT_PID" 2>/dev/null || true
sleep 1
kill -0 "$PERF_STAT_PID" 2>/dev/null && kill -TERM "$PERF_STAT_PID" 2>/dev/null || true
wait "$PERF_STAT_PID" 2>/dev/null || true

fin_str=$(read_utime_stime "$TARGET_VCPU_TID" 2>/dev/null) || fin_str="$init_str"
FINAL_UTIME=${fin_str%% *}
FINAL_STIME=${fin_str##* }
log "final utime=$FINAL_UTIME stime=$FINAL_STIME"

# ---- 停 VM ----
stop_all_vms

# ---- 计算结果 ----
WALL_SEC=$(python3 -c "print(f'{$WINDOW_END - $WINDOW_START:.9f}')")

TASK_CLOCK_MS=$(awk '/task-clock/{
    for(i=1;i<=NF;i++) if($i ~ /^[0-9.,]+$/){gsub(/,/,"",$i); print $i; exit}
}' "$PERF_STAT_OUT" 2>/dev/null || echo "0")
ONCPU_TC=$(python3 -c "print(f'{float(\"$TASK_CLOCK_MS\")/1000:.9f}')")

CPU_CLOCK_MS=$(awk '/cpu-clock/{
    for(i=1;i<=NF;i++) if($i ~ /^[0-9.,]+$/){gsub(/,/,"",$i); print $i; exit}
}' "$PERF_STAT_OUT" 2>/dev/null || echo "0")
ONCPU_CPU_CLOCK=$(python3 -c "print(f'{float(\"$CPU_CLOCK_MS\")/1000:.9f}')")

ONCPU_US=$(python3 -c "
iu=$INIT_UTIME; fu=$FINAL_UTIME; is=$INIT_STIME; fs=$FINAL_STIME; clk=$CLK_TCK
print(f'{((fu-iu)+(fs-is))/clk:.9f}')
")

ONCPU_PCT_TC=$(python3 -c "
w=float('$WALL_SEC'); tc=float('$ONCPU_TC')
print(f'{tc/w*100:.2f}' if w>0 else 'N/A')
")

{
    echo "============================================"
    echo "  perf stat oncpu 采集结果"
    echo "============================================"
    echo ""
    echo "workload          = $TARGET_WORKLOAD"
    echo "mode              = $EXPERIMENT_MODE"
    echo "round             = $ROUND_ID"
    echo "with_noise        = $WITH_NOISE"
    echo "target_tid        = $TARGET_VCPU_TID"
    echo "target_rc         = ${TARGET_EXIT_CODE:-unknown}"
    echo ""
    echo "--- on-CPU time (3 种方法) ---"
    echo "  perf_stat_task_clock_s = $ONCPU_TC"
    echo "  perf_stat_cpu_clock_s = $ONCPU_CPU_CLOCK"
    echo "  proc_pid_stat_s        = $ONCPU_US   (utime+stime / CLK_TCK)"
    echo ""
    echo "--- 墙钟 ---"
    echo "  wall_s                = $WALL_SEC"
    echo "  oncpu_pct (tc/wall)   = $ONCPU_PCT_TC%"
    echo ""
    echo "--- 原始 ---"
    echo "  clk_tck       = $CLK_TCK"
    echo "  init_utime    = $INIT_UTIME"
    echo "  init_stime    = $INIT_STIME"
    echo "  final_utime   = $FINAL_UTIME"
    echo "  final_stime   = $FINAL_STIME"
    echo "  task_clock_ms = $TASK_CLOCK_MS"
    echo "  cpu_clock_ms  = $CPU_CLOCK_MS"
    echo ""
    echo "--- perf stat 原始输出 ---"
    cat "$PERF_STAT_OUT" 2>/dev/null || echo "(空)"
} | tee "$RUN_DIR/xval_summary.txt"

{
    echo "workload=$TARGET_WORKLOAD"
    echo "mode=$EXPERIMENT_MODE"
    echo "round=$ROUND_ID"
    echo "with_noise=$WITH_NOISE"
    echo "wall_s=$WALL_SEC"
    echo "oncpu_task_clock_s=$ONCPU_TC"
    echo "oncpu_cpu_clock_s=$ONCPU_CPU_CLOCK"
    echo "oncpu_proc_stat_s=$ONCPU_US"
    echo "target_tid=$TARGET_VCPU_TID"
} > "$RUN_DIR/xval_result.env"

log "完成 run_dir=$RUN_DIR"
log "target rc=${TARGET_EXIT_CODE:-unknown}"

printf 'XVAL_RESULT,%s,%s,%s,%s,%s,%s,%s\n' \
    "$TARGET_WORKLOAD" "$EXPERIMENT_MODE" "$ROUND_ID" "$WITH_NOISE" \
    "$WALL_SEC" "$ONCPU_TC" "$ONCPU_US"
