# perf.sh -- sourced by fc_sched_experiment.sh; do not run directly. (split from v17 cluster-noise)

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
