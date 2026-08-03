#!/usr/bin/env bash
# run_cluster_noise_batch.sh
# 对 5 个 workload 各跑 2 遍(无噪声 n5 baseline + cluster 噪声 n5), 全部新跑,
# 取每轮 wall_s, 汇总成 cluster_noise_table.csv. 不复用任何旧数据.
set -Eeuo pipefail
export LC_ALL=C

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# 指向要用的入口(v17 单体 或 cluster_noise/fc_sched_experiment.sh 模块版均可)
FC=${FC:-"$SCRIPT_DIR/fc_sched_experiment_v17.sh"}

# ---- 拓扑(全部 NUMA node1, 不跨节点) ----
TARGET_CPU=${TARGET_CPU:-102}
HOUSEKEEPING_CPU=${HOUSEKEEPING_CPU:-112}
CORE0_BG=${CORE0_BG:-3}
NOISE_CPUS=${NOISE_CPUS:-96,98,100,104,106,108,110}
NOISE_WORKLOAD=${NOISE_WORKLOAD:-joke2k__faker-2007}
ROUND=${ROUND:-1}
# 调度模式: n5(默认 CFS) 或 n5_fifo(target fc_vcpu0 用 SCHED_FIFO rt 50)
MODE=${MODE:-n5}

# kernel / ext4 位置(与你单次手动跑一致; 可用环境变量覆盖)
KERNEL_IMAGE=${KERNEL_IMAGE:-"$SCRIPT_DIR/ub_latency/vmlinux-fc-arm64"}
IMAGE_DIR=${IMAGE_DIR:-"$SCRIPT_DIR/ub_latency/ext4"}

WORKLOADS=(
    SpikeInterface__spikeinterface-1057
    12rambau__sepal_ui-747
    abhinavsingh__proxy.py-740
    mathandy__svgpathtools-170
    joke2k__faker-2007
)

die() { printf '[batch] ERROR: %s\n' "$*" >&2; exit 1; }
[[ $(id -u) -eq 0 ]] || die "必须 root 运行(perf/KVM)"
[[ -x $FC ]] || die "找不到可执行入口: $FC"
[[ -f $KERNEL_IMAGE ]] || die "KERNEL_IMAGE 不存在: $KERNEL_IMAGE (设 KERNEL_IMAGE=... 覆盖)"
[[ -d $IMAGE_DIR ]] || die "IMAGE_DIR 不存在: $IMAGE_DIR (设 IMAGE_DIR=... 覆盖)"

LOG_DIR="$SCRIPT_DIR/batch_logs_${MODE}"
TABLE="$SCRIPT_DIR/cluster_noise_table_${MODE}.csv"
mkdir -p "$LOG_DIR"
printf 'workload,round,core0_bg,noise_cpus,baseline_wall_s,cluster_noise_wall_s,delta_s,delta_pct\n' >"$TABLE"

wall_s() { awk -F, 'NR==2{print $4}' "$1" 2>/dev/null; }

# 跑一次 n5, 返回 run_dir. $1=workload $2=是否噪声(0/1) $3=日志前缀
run_once() {
    local wl=$1 with_noise=$2 tag=$3 logf args
    logf="$LOG_DIR/${tag}_${wl}.log"
    if [[ $with_noise == 1 ]]; then
        args=(CLUSTER_NOISE_CPUS="$NOISE_CPUS" CLUSTER_NOISE_WORKLOAD="$NOISE_WORKLOAD")
    else
        args=(CLUSTER_NOISE_CPUS=)
    fi
    printf '[batch] (%s) 开始: %s  noise=%s\n' "$tag" "$wl" "$with_noise" >&2
    rm -f /tmp/fc-exp-*.sock /tmp/fc-exp-noise-*.sock 2>/dev/null || true
    set +e
    env TARGET_CPU="$TARGET_CPU" HOUSEKEEPING_CPU="$HOUSEKEEPING_CPU" \
        KERNEL_IMAGE="$KERNEL_IMAGE" IMAGE_DIR="$IMAGE_DIR" \
        CORE0_BG="$CORE0_BG" "${args[@]}" \
        "$FC" run "$MODE" "$wl" "$ROUND" >"$logf" 2>&1
    local rc=$?
    set -e
    local rd
    rd=$(sed -n 's/.*实验完成 run_dir=//p' "$logf" | tail -1)
    if [[ -z $rd || ! -r $rd/summary.csv ]]; then
        printf '[batch] (%s) 失败 rc=%s, 详见 %s\n' "$tag" "$rc" "$logf" >&2
        return 1
    fi
    printf '[batch] (%s) 完成 wall_s=%s  rc=%s  log=%s\n' \
        "$tag" "$(wall_s "$rd/summary.csv")" "$rc" "$logf" >&2
    printf '%s\n' "$rd"
}

printf '[batch] 开始: 5 workload x 2 (baseline+noise) = 10 轮, %s\n' "$(date '+%F %T')"
printf '[batch] 入口=%s MODE=%s TARGET_CPU=%s HK=%s CORE0_BG=%s NOISE=%s\n' \
    "$FC" "$MODE" "$TARGET_CPU" "$HOUSEKEEPING_CPU" "$CORE0_BG" "$NOISE_CPUS"

for wl in "${WORKLOADS[@]}"; do
    printf '\n==== workload=%s ====\n' "$wl"
    base_dir=$(run_once "$wl" 0 baseline) || base_dir=""
    noise_dir=$(run_once "$wl" 1 noise) || noise_dir=""

    bw=""; nw=""
    [[ -n $base_dir ]] && bw=$(wall_s "$base_dir/summary.csv")
    [[ -n $noise_dir ]] && nw=$(wall_s "$noise_dir/summary.csv")

    delta="" pct=""
    if [[ -n $bw && -n $nw ]]; then
        delta=$(awk -v n="$nw" -v b="$bw" 'BEGIN{printf "%.6f", n-b}')
        pct=$(awk -v n="$nw" -v b="$bw" 'BEGIN{printf "%.2f", (b+0>0?100*(n-b)/b:0)}')
    fi
    printf '%s,%s,%s,%s,%s,%s,%s,%s\n' \
        "$wl" "$ROUND" "$CORE0_BG" "${NOISE_CPUS//,/;}" \
        "${bw:-FAILED}" "${nw:-FAILED}" "$delta" "$pct" >>"$TABLE"
done

printf '\n[batch] 全部完成: %s\n' "$(date '+%F %T')"
printf '==== 汇总表 (%s) ====\n' "$TABLE"
if command -v column >/dev/null; then column -t -s, "$TABLE"; else cat "$TABLE"; fi
