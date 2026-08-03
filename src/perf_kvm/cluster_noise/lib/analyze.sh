# analyze.sh -- sourced by fc_sched_experiment.sh; do not run directly. (split from v17 cluster-noise)
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
        -v cause_window_us="$WAKE_CAUSE_WINDOW_US" \
        -f "$ANALYZER_AWK" "$RUN_DIR/perf.txt" | tee "$RUN_DIR/summary.txt"

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
