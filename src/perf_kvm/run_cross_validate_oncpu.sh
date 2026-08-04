#!/usr/bin/env bash
# run_cross_validate_oncpu.sh
# 3 种方法同时测 target vCPU 的 oncpu time，交叉验证 v17 的 sched_switch 累加:
#   1) sched_switch 累加  — v17 原有，从 run_dir/summary.csv 读 oncpu_s
#   2) perf stat task-clock — 新加，监听 v17 log，replay 开始时启动 perf stat -t <tid>
#   3) /proc/<tid>/stat    — 新加，replay 开始/完成时各读一次 utime+stime，差值/CLK_TCK
# 复用 v17 的 VM 启动 + cluster noise + FIFO + perf record 控制窗口，只在窗口内额外加 perf stat

set -Eeuo pipefail
export LC_ALL=C

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
FC=${FC:-"$SCRIPT_DIR/fc_sched_experiment_v17.sh"}

TARGET_CPU=${TARGET_CPU:-102}
HOUSEKEEPING_CPU=${HOUSEKEEPING_CPU:-112}
CORE0_BG=${CORE0_BG:-3}
NOISE_CPUS=${NOISE_CPUS:-96,98,100,104,106,108,110}
NOISE_WORKLOAD=${NOISE_WORKLOAD:-joke2k__faker-2007}
ROUND=${ROUND:-1}
MODE=${MODE:-n5}

KERNEL_IMAGE=${KERNEL_IMAGE:-"$SCRIPT_DIR/ub_latency/vmlinux-fc-arm64"}
IMAGE_DIR=${IMAGE_DIR:-"$SCRIPT_DIR/ub_latency/ext4"}

WORKLOADS=(
    SpikeInterface__spikeinterface-1057
    12rambau__sepal_ui-747
    abhinavsingh__proxy.py-740
    mathandy__svgpathtools-170
    joke2k__faker-2007
)

die() { printf '[xval] ERROR: %s\n' "$*" >&2; exit 1; }
[[ $(id -u) -eq 0 ]] || die "必须 root"
[[ -x $FC ]] || die "找不到 $FC"
[[ -f $KERNEL_IMAGE ]] || die "KERNEL_IMAGE 不存在: $KERNEL_IMAGE"
[[ -d $IMAGE_DIR ]] || die "IMAGE_DIR 不存在: $IMAGE_DIR"

LOG_DIR="$SCRIPT_DIR/xval_logs_${MODE}"
TABLE="$SCRIPT_DIR/xval_oncpu_${MODE}.csv"
mkdir -p "$LOG_DIR"
printf 'workload,mode,type,wall_s,oncpu_sched_switch_s,oncpu_task_clock_s,oncpu_utime_stime_s,delta_sc_vs_tc_pct,delta_sc_vs_us_pct\n' >"$TABLE"

CLK_TCK=$(getconf CLK_TCK)

read_utime_stime() {
    local tid=$1 line fields
    line=$(cat /proc/$tid/stat 2>/dev/null) || return 1
    fields="${line##*)}"
    local arr
    read -ra arr <<< "$fields"
    echo "${arr[11]} ${arr[12]}"
}

get_task_clock_ms() {
    awk '/task-clock/{
        for(i=1;i<=NF;i++) if($i ~ /^[0-9.,]+$/){gsub(/,/,"",$i); print $i; exit}
    }' "$1" 2>/dev/null
}

run_once() {
    local wl=$1 with_noise=$2
    local tag=$([ $with_noise -eq 1 ] && echo noise || echo baseline)
    local logf="$LOG_DIR/${tag}_${wl}.log"
    local perf_stat_out="$LOG_DIR/${tag}_${wl}.perf_stat.txt"
    local proc_stat_out="$LOG_DIR/${tag}_${wl}.proc_stat.txt"
    local perf_stdout="$LOG_DIR/${tag}_${wl}.perf_stdout.log"

    local args
    if [[ $with_noise == 1 ]]; then
        args=(CLUSTER_NOISE_CPUS="$NOISE_CPUS" CLUSTER_NOISE_WORKLOAD="$NOISE_WORKLOAD")
    else
        args=(CLUSTER_NOISE_CPUS=)
    fi

    printf '[xval] (%s) 开始: %s noise=%s\n' "$tag" "$wl" "$with_noise" >&2
    rm -f /tmp/fc-exp-*.sock /tmp/fc-exp-noise-*.sock 2>/dev/null || true

    local target_tid=""
    local perf_pid=""
    local perf_started=0
    local init_utime="" init_stime=""
    local final_utime="" final_stime=""
    local rd=""

    set +e
    while IFS= read -r line; do
        printf '%s\n' "$line" >> "$logf"

        if [[ $line == *"被观测线程 target_vcpu_tid="* ]]; then
            target_tid=$(printf '%s' "$line" | grep -oP 'target_vcpu_tid=\K[0-9]+')
            printf '[xval] caught tid=%s\n' "$target_tid" >&2
        fi

        if [[ $line == *"target replay 已开始"* && -n $target_tid && $perf_started == 0 ]]; then
            local init_str
            init_str=$(read_utime_stime "$target_tid") || init_str="0 0"
            init_utime=${init_str%% *}
            init_stime=${init_str##* }
            perf stat -t "$target_tid" -e task-clock,cpu-clock \
                -o "$perf_stat_out" >"$perf_stdout" 2>&1 &
            perf_pid=$!
            perf_started=1
            printf '[xval] perf stat started pid=%s tid=%s init_utime=%s init_stime=%s\n' \
                "$perf_pid" "$target_tid" "$init_utime" "$init_stime" >&2
        fi

        if [[ $line == *"target 已完成"* && $perf_started == 1 ]]; then
            kill -INT "$perf_pid" 2>/dev/null || true
            sleep 1
            kill -0 "$perf_pid" 2>/dev/null && kill -TERM "$perf_pid" 2>/dev/null || true
            wait "$perf_pid" 2>/dev/null || true
            perf_started=0
            local fin_str
            fin_str=$(read_utime_stime "$target_tid") || fin_str="$init_utime $init_stime"
            final_utime=${fin_str%% *}
            final_stime=${fin_str##* }
            printf '[xval] perf stat stopped final_utime=%s final_stime=%s\n' \
                "$final_utime" "$final_stime" >&2
        fi

        if [[ $line == *"实验完成 run_dir="* ]]; then
            rd=$(printf '%s' "$line" | grep -oP 'run_dir=\K\S+')
        fi
    done < <(stdbuf -oL -eL env TARGET_CPU="$TARGET_CPU" HOUSEKEEPING_CPU="$HOUSEKEEPING_CPU" \
        KERNEL_IMAGE="$KERNEL_IMAGE" IMAGE_DIR="$IMAGE_DIR" \
        CORE0_BG="$CORE0_BG" "${args[@]}" \
        "$FC" run "$MODE" "$wl" "$ROUND" 2>&1)
    local rc=$?
    set -e

    if [[ $perf_started == 1 && -n $perf_pid ]]; then
        kill -INT "$perf_pid" 2>/dev/null || true
        sleep 1
        kill -0 "$perf_pid" 2>/dev/null && kill -TERM "$perf_pid" 2>/dev/null || true
        wait "$perf_pid" 2>/dev/null || true
        [[ -z $final_utime && -n $target_tid ]] && {
            local fin_str
            fin_str=$(read_utime_stime "$target_tid") || fin_str="$init_utime $init_stime"
            final_utime=${fin_str%% *}
            final_stime=${fin_str##* }
        }
    fi
    sleep 1

    local sc_oncpu="" wall=""
    if [[ -n $rd && -r $rd/summary.csv ]]; then
        sc_oncpu=$(awk -F, 'NR==2{print $23}' "$rd/summary.csv" 2>/dev/null)
        wall=$(awk -F, 'NR==2{print $4}' "$rd/summary.csv" 2>/dev/null)
    fi

    local tc_oncpu=""
    if [[ -f $perf_stat_out ]]; then
        local tc_ms
        tc_ms=$(get_task_clock_ms "$perf_stat_out")
        if [[ -n $tc_ms ]]; then
            tc_oncpu=$(python3 -c "print(f'{float(\"$tc_ms\")/1000:.9f}')")
        fi
    fi

    local us_oncpu=""
    if [[ -n $init_utime && -n $final_utime ]]; then
        us_oncpu=$(python3 -c "
iu=$init_utime; fu=$final_utime; is=$init_stime; fs=$final_stime; clk=$CLK_TCK
print(f'{((fu-iu)+(fs-is))/clk:.9f}')
")
    fi

    {
        echo "init_utime=$init_utime"
        echo "init_stime=$init_stime"
        echo "final_utime=$final_utime"
        echo "final_stime=$final_stime"
        echo "clk_tck=$CLK_TCK"
        echo "total_cpu_sec=$us_oncpu"
    } > "$proc_stat_out"

    local d_sc_tc="" d_sc_us=""
    if [[ -n $sc_oncpu && -n $tc_oncpu && $sc_oncpu != 0 ]]; then
        d_sc_tc=$(python3 -c "
sc=float(\"$sc_oncpu\"); tc=float(\"$tc_oncpu\")
print(f'{100*(tc-sc)/sc:.2f}')")
    fi
    if [[ -n $sc_oncpu && -n $us_oncpu && $sc_oncpu != 0 ]]; then
        d_sc_us=$(python3 -c "
sc=float(\"$sc_oncpu\"); us=float(\"$us_oncpu\")
print(f'{100*(us-sc)/sc:.2f}')")
    fi

    printf '[xval] (%s) 完成 wall=%s sc=%s tc=%s us=%s (Δtc=%s%% Δus=%s%%)\n' \
        "$tag" "$wall" "$sc_oncpu" "$tc_oncpu" "$us_oncpu" \
        "${d_sc_tc:-NA}" "${d_sc_us:-NA}" >&2

    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
        "$wl" "$MODE" "$tag" \
        "${wall:-NA}" "${sc_oncpu:-NA}" "${tc_oncpu:-NA}" "${us_oncpu:-NA}" \
        "${d_sc_tc:-NA}" "${d_sc_us:-NA}" >>"$TABLE"
}

printf '[xval] 开始: 5 workload x 2 (baseline+noise) = 10 轮, MODE=%s\n' "$MODE"
printf '[xval] 入口=%s TARGET_CPU=%s HK=%s MODE=%s NOISE=%s\n' \
    "$FC" "$TARGET_CPU" "$HOUSEKEEPING_CPU" "$MODE" "$NOISE_CPUS"

for wl in "${WORKLOADS[@]}"; do
    printf '\n==== workload=%s ====\n' "$wl"
    run_once "$wl" 0 || true
    run_once "$wl" 1 || true
done

printf '\n[xval] 全部完成\n'
printf '==== oncpu 三方法对比 (%s) ====\n' "$TABLE"
column -t -s, "$TABLE" 2>/dev/null || cat "$TABLE"
