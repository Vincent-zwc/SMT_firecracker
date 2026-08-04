#!/usr/bin/env bash
# run_perf_stat_batch.sh
# 跑 5 workload × (baseline+noise) = 10 轮 perf stat 采集
# 每轮只用 perf stat task-clock + /proc/pid/stat（单一 perf 进程，零干扰）
# 输出 xval_oncpu_<mode>.csv 对比表

set -Eeuo pipefail
export LC_ALL=C

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
RUNNER="$SCRIPT_DIR/run_perf_stat_oncpu.sh"

MODE=${MODE:-n5}
ROUND=${ROUND:-1}
NOISE_CPUS=${NOISE_CPUS:-96,98,100,104,106,108,110}
NOISE_WORKLOAD=${NOISE_WORKLOAD:-joke2k__faker-2007}

WORKLOADS=(
    SpikeInterface__spikeinterface-1057
    12rambau__sepal_ui-747
    abhinavsingh__proxy.py-740
    mathandy__svgpathtools-170
    joke2k__faker-2007
)

die() { printf '[xval-batch] ERROR: %s\n' "$*" >&2; exit 1; }
[[ $(id -u) -eq 0 ]] || die "必须 root"
[[ -x $RUNNER ]] || die "找不到 $RUNNER"

LOG_DIR="$SCRIPT_DIR/xval_logs_${MODE}"
TABLE="$SCRIPT_DIR/xval_oncpu_${MODE}.csv"
mkdir -p "$LOG_DIR"
printf 'workload,mode,round,type,wall_s,oncpu_task_clock_s,oncpu_proc_stat_s,oncpu_pct\n' >"$TABLE"

printf '[xval-batch] 开始: 5 workload x 2 = 10 轮, MODE=%s\n' "$MODE"

for wl in "${WORKLOADS[@]}"; do
    for noise in 0 1; do
        tag=$([ $noise -eq 1 ] && echo noise || echo baseline)
        logf="$LOG_DIR/${tag}_${wl}.log"

        printf '[xval-batch] (%s) 开始: %s\n' "$tag" "$wl" >&2

        set +e
        if [[ $noise == 1 ]]; then
            env CLUSTER_NOISE_CPUS="$NOISE_CPUS" CLUSTER_NOISE_WORKLOAD="$NOISE_WORKLOAD" \
                "$RUNNER" "$MODE" "$wl" "$ROUND" 1 >"$logf" 2>&1
        else
            env CLUSTER_NOISE_CPUS= \
                "$RUNNER" "$MODE" "$wl" "$ROUND" 0 >"$logf" 2>&1
        fi
        rc=$?
        set -e

        result=$(grep '^XVAL_RESULT,' "$logf" | tail -1)
        if [[ -z $result ]]; then
            printf '[xval-batch] (%s) 失败 rc=%s, 详见 %s\n' "$tag" "$rc" "$logf" >&2
            printf '%s,%s,%s,%s,FAILED,FAILED,FAILED,NA\n' "$wl" "$MODE" "$ROUND" "$tag" >>"$TABLE"
            continue
        fi

        IFS=, read -r _ wl mode rnd noise_t wall tc us <<< "$result"
        pct=$(python3 -c "
w=float('$wall'); tc=float('$tc')
print(f'{tc/w*100:.2f}' if w>0 else 'N/A')
" 2>/dev/null || echo "NA")

        printf '%s,%s,%s,%s,%s,%s,%s,%s\n' \
            "$wl" "$mode" "$rnd" "$tag" "$wall" "$tc" "$us" "$pct" >>"$TABLE"
        printf '[xval-batch] (%s) 完成 wall=%s tc=%s us=%s pct=%s%%\n' \
            "$tag" "$wall" "$tc" "$us" "$pct" >&2
    done
done

printf '\n[xval-batch] 全部完成\n'
printf '==== perf stat oncpu 对比表 (%s) ====\n' "$TABLE"
column -t -s, "$TABLE" 2>/dev/null || cat "$TABLE"
