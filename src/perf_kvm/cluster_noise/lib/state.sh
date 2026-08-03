# state.sh -- sourced by fc_sched_experiment.sh; do not run directly. (split from v17 cluster-noise)

# ============================= 运行期状态变量 =================================

# workload 配置解析后的结果：
#   ALL_WORKLOADS          表中所有 workload，保持表内顺序
#   CASE_WORKLOADS[0]      本轮 target
#   CASE_WORKLOADS[1..4]   N=5 时的四个 background
#   *_OF[workload名称]     根据名称查询对应配置
declare -a ALL_WORKLOADS CASE_WORKLOADS
declare -A ROOTFS_OF GUEST_REPO_OF COMMIT_OF REPLAY_OF

# VM 运行期信息。这里不用“对象”或复杂数据结构，只使用相同下标关联数据：
#   VM_PROCESS_PID[0] 与 VM_CONSOLE_LOG[0] 都属于 target；
#   N=5 时，下标 1～4 属于四个 background。
declare -a VM_PROCESS_PID VM_INPUT_FD VM_CONSOLE_LOG
declare -a VM_ROOTFS VM_API_SOCKET VM_STDIN_FIFO

# cluster 噪声 VM 的运行期信息，与核0 VM 数组平行但独立下标，避免和 perf 过滤
# 用的 target/background 编号混在一起。NOISE_CPU[$i] 记录该 VM 独占的核。
declare -a NOISE_PID NOISE_CPU NOISE_WL NOISE_ROOTFS NOISE_CONSOLE_LOG
declare -a NOISE_INPUT_FD NOISE_API_SOCKET NOISE_STDIN_FIFO
CLUSTER_NOISE_CPU_LIST=()
NOISE_COUNT=0

# 当前实验的公共状态。函数之间需要共享这些值，因此不声明为局部变量。
EXPERIMENT_MODE=
TARGET_WORKLOAD=
ROUND_ID=
RUN_DIR=
TARGET_VCPU_TID=
PERF_RECORD_PID=
PERF_CONTROL_FD=
PERF_ACK_FD=
PERF_CONTROL_FIFO=
PERF_ACK_FIFO=
PERF_EVENTS_ENABLED=0
PERF_DISABLE_ACK_MS=
WINDOW_START_TIME=
WINDOW_END_TIME=
TARGET_EXIT_CODE=
TARGET_SCHED_POLICY=
TARGET_SCHED_PRIORITY=
HOST_SCHED_RT_PERIOD_US=
HOST_SCHED_RT_RUNTIME_US=
