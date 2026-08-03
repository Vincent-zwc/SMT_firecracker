# run.sh -- sourced by fc_sched_experiment.sh; do not run directly. (split from v17 cluster-noise)

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
