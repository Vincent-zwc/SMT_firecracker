#!/usr/bin/env bash
# run_perf_stat_batch_standalone.sh
# 跑 5 workload x (CFS + FIFO) = 10 轮 perf stat 采集
# 输出 perf_stat_oncpu.csv 对比表

set -Eeuo pipefail
export LC_ALL=C

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
RUNNER="$SCRIPT_DIR/run_perf_stat_standalone.sh"

MODE=${MODE:-n5}
ROUND=${ROUND:-1}

WORKLOADS=(
    SpikeInterface__spikeinterface-1057
    12rambau__sepal_ui-747
    abhinavsingh__proxy.py-740
    mathandy__svgpathtools-170
    joke2k__faker-2007
)

die() { printf '[batch] ERROR: %s\n' "$*" >&2; exit 1; }
[[ $(id -u) -eq 0 ]] || die "必须 root"
[[ -f $RUNNER ]] || die "找不到 $RUNNER"

LOG_DIR="$SCRIPT_DIR/perf_stat_logs_${MODE}"
TABLE="$SCRIPT_DIR/perf_stat_oncpu_${MODE}.csv"
mkdir -p "$LOG_DIR"
printf 'workload,mode,fifo,wall_s,oncpu_task_clock_s,oncpu_cpu_clock_s,oncpu_proc_stat_s,oncpu_pct\n' >"$TABLE"

printf '[batch] 开始: 5 workload x 2 (CFS+FIFO) = 10 轮, MODE=%s\n' "$MODE"

for wl in "${WORKLOADS[@]}"; do
    for fifo in 0 1; do
        tag=$([ $fifo -eq 1 ] && echo fifo || echo cfs)
        logf="$LOG_DIR/${tag}_${wl}.log"

        printf '[batch] (%s) 开始: %s\n' "$tag" "$wl" >&2

        set +e
        SCHED_FIFO=$fifo "$RUNNER" "$wl" "$MODE" "$ROUND" >"$logf" 2>&1
        rc=$?
        set -e

        result=$(grep '^PERF_STAT_RESULT,' "$logf" | tail -1)
        if [[ -z $result ]]; then
            printf '[batch] (%s) 失败 rc=%s, 详见 %s\n' "$tag" "$rc" "$logf" >&2
            printf '%s,%s,%s,FAILED,FAILED,FAILED,FAILED,NA\n' "$wl" "$MODE" "$fifo" >>"$TABLE"
            continue
        fi

        IFS=, read -r _ wl_name mode rnd sched_fifo wall tc cc us <<< "$result"
        pct=$(python3 -c "
w=float('$wall'); tc=float('$tc')
print(f'{tc/w*100:.2f}' if w>0 else 'N/A')
" 2>/dev/null || echo "NA")

        printf '%s,%s,%s,%s,%s,%s,%s,%s\n' \
            "$wl_name" "$mode" "$sched_fifo" "$wall" "$tc" "$cc" "$us" "$pct" >>"$TABLE"
        printf '[batch] (%s) 完成 wall=%s tc=%s us=%s pct=%s%%\n' \
            "$tag" "$wall" "$tc" "$us" "$pct" >&2
    done
done

printf '\n[batch] 全部完成\n'
printf '==== perf stat oncpu 对比表 (%s) ====\n' "$TABLE"
column -t -s, "$TABLE" 2>/dev/null || cat "$TABLE"
