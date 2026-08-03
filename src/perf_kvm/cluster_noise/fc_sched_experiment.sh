#!/usr/bin/env bash
# fc_sched_experiment.sh -- modular entry (v17 cluster-noise).
# Logic split into lib/*.sh; AWK analyzer at lib/analyze_perf.awk.
# Usage/args/features identical to the v17 monolith: run/compare/analyze/walltime.
set -Eeuo pipefail
export LC_ALL=C
shopt -u varredir_close 2>/dev/null || true

readonly SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

for _m in common config state workload environment guest vm perf analyze compare run; do
    source "$SCRIPT_DIR/lib/${_m}.sh"
done
readonly ANALYZER_AWK="$SCRIPT_DIR/lib/analyze_perf.awk"

usage() {
    cat <<EOF
运行一个实验 case：
  sudo env TARGET_CPU=102 HOUSEKEEPING_CPU=0 \\
    $0 run <n1|n5|n5_fifo> <target-workload> <round>

默认资源位置（均相对于本脚本）：
  kernel：$SCRIPT_DIR/vmlinux-fc-arm64
  ext4：  $SCRIPT_DIR/ext4/base-*.ext4
  如文件位于其他目录，可用 KERNEL_IMAGE 和 IMAGE_DIR 环境变量覆盖。

日志：
  默认保存 target replay 的 stdout/stderr 到每轮结果目录的 replay.log。
  如需与旧版丢弃输出的行为严格一致，启动时设置 SAVE_REPLAY_LOG=0。

参数含义：
  n1               单 VM，全部线程使用默认 CFS
  n5               五台完整 VM 共享一个宿主机 CPU，全部线程使用默认 CFS
  n5_fifo          与 n5 相同，但仅 target 的 fc_vcpu 0 使用 SCHED_FIFO
  target-workload  workload_table 中被观测任务的名称
  round            重复实验的轮次编号，例如 1、2、3

FIFO 优先级：
  n5_fifo 默认使用实时优先级 50，可通过 TARGET_FIFO_PRIORITY=数值覆盖。
  允许范围为 1～99。脚本会逐线程验证，确保只有 target vCPU 是 FIFO。

比较同一个 target、同一个 round：
  $0 compare <n1-summary.csv> <n5-summary.csv> [comparison.csv]
  $0 compare <n5-summary.csv> <n5_fifo-summary.csv> [comparison.csv]

只取/对比 target 的墙钟耗时（wall_s，即"action 总耗时"）：
  $0 walltime <summary.csv>                          # 打印 workload/round/wall_s
  $0 walltime <噪声summary.csv> <baseline_summary.csv>  # 输出 baseline/噪声/delta 一行

cluster 噪声（v17 新增，仅在 n5/n5_fifo 下生效，默认关闭）：
  sudo env TARGET_CPU=0 HOUSEKEEPING_CPU=8 \\
        CORE0_BG=3 CLUSTER_NOISE_CPUS=1,2,3,4,5,6,7 \\
        CLUSTER_NOISE_WORKLOAD=joke2k__faker-2007 \\
        $0 run n5 <target-workload> <round>
    CORE0_BG            核0 background 数（默认 4；设 3 即"3背景1测试"）
    CLUSTER_NOISE_CPUS  各噪声 VM 独占的核，逗号分隔（留空=不启用）
    CLUSTER_NOISE_WORKLOAD  噪声 VM 跑的 workload（缺省用 target）
    CLUSTER_NOISE_WARMUP    噪声额外预热秒数（默认 10）

只重新分析已经采集完成的结果，不重新启动 VM：
  sudo env KERNEL_IMAGE=/实际路径/vmlinux-fc-arm64 \\
    $0 analyze <run_dir>

新版本生成的 run.env 会记录 kernel_image，后续重新分析时通常不必再次指定。
旧版本结果没有该字段，且 kernel 不在脚本默认位置时，需要显式传 KERNEL_IMAGE。
EOF
}
main() {
    local command=${1:-help}
    [[ $# -eq 0 ]] || shift

    case $command in
        run)
            run_experiment "$@"
            ;;
        compare)
            [[ $# -eq 2 || $# -eq 3 ]] || { usage; return 2; }
            compare_runs "$1" "$2" "${3:-$(dirname "$2")/comparison.csv}"
            ;;
        walltime)
            walltime "$@"
            ;;
        analyze)
            analyze_existing_run "$@"
            ;;
        help|-h|--help)
            usage
            ;;
        *)
            usage >&2
            return 2
            ;;
    esac
}

main "$@"
