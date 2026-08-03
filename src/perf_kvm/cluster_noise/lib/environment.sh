# environment.sh -- sourced by fc_sched_experiment.sh; do not run directly. (split from v17 cluster-noise)

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
