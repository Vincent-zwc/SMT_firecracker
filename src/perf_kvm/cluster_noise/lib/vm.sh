# vm.sh -- sourced by fc_sched_experiment.sh; do not run directly. (split from v17 cluster-noise)

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
    [[ ${#NOISE_PID[@]:-0} -eq 0 ]] && return 0
    local idx pid
    for ((idx=0; idx<${#NOISE_PID[@]:-0}; idx++)); do
        pid=${NOISE_PID[$idx]:-}
        [[ -n $pid ]] || continue
        kill -TERM "$pid" 2>/dev/null || true
    done
    sleep 0.2
    for ((idx=0; idx<${#NOISE_PID[@]:-0}; idx++)); do
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
