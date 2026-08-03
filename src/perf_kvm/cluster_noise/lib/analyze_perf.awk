# analyze_perf.awk -- invoked by analyze.sh via `awk -f`; vars passed with -v.
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
