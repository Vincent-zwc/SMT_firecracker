#!/usr/bin/env bash
# run_perf_stat_batch_standalone.sh
# 跑 5 workload × (CFS+FIFO) × (baseline+noise) = 20 轮 perf stat 采集
# 输出 perf_stat_oncpu.csv 对比表
#
# 用法:
#   sudo ./run_perf_stat_batch_standalone.sh              # 全 20 轮
#   sudo MODE=n1 ./run_perf_stat_batch_standalone.sh       # n1 单VM, 20 轮
#   sudo WITH_NOISE=0 ./run_perf_stat_batch_standalone.sh  # 只跑 baseline, 10 轮

set -Eeuo pipefail
export LC_ALL=C

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
RUNNER="$SCRIPT_DIR/run_perf_stat_standalone.sh"

MODE=${MODE:-n5}
ROUND=${ROUND:-1}
WITH_NOISE=${WITH_NOISE:-1}
NOISE_CPUS=${NOISE_CPUS:-96,98,100,104,106,108,110}
NOISE_WORKLOAD=${NOISE_WORKLOAD:-joke2k__faker-2007}

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
printf 'workload,mode,fifo,noise,wall_s,oncpu_task_clock_s,oncpu_cpu_clock_s,oncpu_proc_stat_s,oncpu_pct\n' >"$TABLE"

TOTAL=$((${#WORKLOADS[@]} * 2 * ($WITH_NOISE + 1)))
printf '[batch] 开始: %d 轮, MODE=%s WITH_NOISE=%d\n' "$TOTAL" "$MODE" "$WITH_NOISE"

idx=0
for wl in "${WORKLOADS[@]}"; do
    for fifo in 0 1; do
        for noise in 0 $((WITH_NOISE == 1 ? 1 : 0)); do
            [[ $noise == 0 || $WITH_NOISE == 1 ]] || continue
            idx=$((idx + 1))
            tag=$([ $fifo == 1 ] && echo fifo || echo cfs)
            [[ $noise == 1 ]] && tag="${tag}_noise" || tag="${tag}_base"
            logf="$LOG_DIR/${tag}_${wl}.log"

            printf '[batch] [%d/%d] (%s) 开始: %s\n' "$idx" "$TOTAL" "$tag" "$wl" >&2

            set +e
            if [[ $noise == 1 ]]; then
                env SCHED_FIFO=$fifo \
                    CLUSTER_NOISE_CPUS="$NOISE_CPUS" \
                    CLUSTER_NOISE_WORKLOAD="$NOISE_WORKLOAD" \
                    "$RUNNER" "$wl" "$MODE" "$ROUND" >"$logf" 2>&1
            else
                env SCHED_FIFO=$fifo CLUSTER_NOISE_CPUS= \
                    "$RUNNER" "$wl" "$MODE" "$ROUND" >"$logf" 2>&1
            fi
            rc=$?
            set -e

            result=$(grep '^PERF_STAT_RESULT,' "$logf" | tail -1)
            if [[ -z $result ]]; then
                printf '[batch] [%d/%d] (%s) 失败 rc=%s\n' "$idx" "$TOTAL" "$tag" "$rc" >&2
                printf '%s,%s,%s,%s,FAILED,FAILED,FAILED,FAILED,NA\n' \
                    "$wl" "$MODE" "$fifo" "$noise" >>"$TABLE"
                continue
            fi

            IFS=, read -r _ wl_name mode rnd sched_fifo noise_flag wall tc cc us <<< "$result"
            pct=$(python3 -c "
w=float('$wall'); tc=float('$tc')
print(f'{tc/w*100:.2f}' if w>0 else 'N/A')
" 2>/dev/null || echo "NA")

            printf '%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
                "$wl_name" "$mode" "$sched_fifo" "$noise_flag" \
                "$wall" "$tc" "$cc" "$us" "$pct" >>"$TABLE"
            printf '[batch] [%d/%d] (%s) 完成 wall=%s tc=%s pct=%s%%\n' \
                "$idx" "$TOTAL" "$tag" "$wall" "$tc" "$pct" >&2
        done
    done
done

printf '\n[batch] 全部完成 (%d 轮)\n' "$idx"
printf '==== perf stat oncpu 对比表 (%s) ====\n' "$TABLE"
column -t -s, "$TABLE" 2>/dev/null || cat "$TABLE"
