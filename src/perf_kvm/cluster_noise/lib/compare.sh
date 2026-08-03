# compare.sh -- sourced by fc_sched_experiment.sh; do not run directly. (split from v17 cluster-noise)

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
