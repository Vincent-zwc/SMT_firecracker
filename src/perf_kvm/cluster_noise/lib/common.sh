# common.sh -- sourced by fc_sched_experiment.sh; do not run directly. (split from v17 cluster-noise)
#!/usr/bin/env bash
# ==============================================================================
# fc_sched_experiment.sh
# 直接使用 Firecracker 的 N=1 / N=5 / N=5-FIFO 单核调度实验脚本
# ==============================================================================
#
# 一、实验要回答的问题
# ------------------------------------------------------------------------------
# 在 N=5 单核超分时，被观测 Firecracker vCPU 的“主动调出”为什么比 N=1 多：
#
#   1. 多出来的主动调出有多少次；
#   2. 其中多少由 guest 执行 WFI/WFE 引起；
#   3. 不能归因于 WFI/WFE 的 other 类型有多少；
#   4. WFI 后由什么事件唤醒：虚拟定时器、虚拟中断还是暂时无法归因；
#   5. 超分增加的是 vCPU 真正阻塞时间，还是唤醒后的就绪排队时间。
#
# 二、三种实验模式
# ------------------------------------------------------------------------------
# N=1：只启动被观测 microVM，被观测 workload 只执行一次。
#
# N=5：先启动 4 台 background microVM，每台 background 在 guest 内循环
#      replay；预热完成后再启动 target，target workload 只执行一次。
#      5 个完整 Firecracker 进程的全部宿主机线程共享 TARGET_CPU。
#
# N=5-FIFO：VM 数量、负载和绑核方式与 N=5 完全相同；只把 target 的
#           “fc_vcpu 0”线程设置为 SCHED_FIFO，其他所有 Firecracker
#           线程仍为 SCHED_OTHER（CFS）。该模式用于区分：
#
#             - 超分后增加的调出是否主要来自 CFS 对 target vCPU 的抢占；
#             - target vCPU 获得实时优先级后，WFI 次数及唤醒原因是否改变。
#
# 注意：FIFO 只是一项调度对照实验，不是生产配置建议。脚本不会修改宿主机
# sched_rt_runtime_us，也不会把 Firecracker 的其他线程迁出实验核。
#
# 三、主动/被动调出的判定
# ------------------------------------------------------------------------------
# 只分析 target 的 “fc_vcpu 0” 宿主机线程：
#
#   prev_state 以 R 开头：vCPU 仍可运行却被换下 CPU，记为被动调出
#                         （passive，通常就是被其他线程抢占）。
#
#   prev_state 不以 R 开头：vCPU 已睡眠/阻塞并放弃 CPU，记为主动调出
#                            （voluntary）。这里的“主动”是 Linux 调度意义
#                            上的 voluntary，不代表 guest 用户程序一定显式
#                            调用了 sched_yield。
#
# 对主动调出继续使用 KVM tracepoint 分类：
#   - guest 执行 WFI：wfi；
#   - guest 执行 WFE：wfe；
#   - 没有对应 WFI/WFE：other，并记录最近一次 kvm_exit 上下文。
#
# KVM 内部一次中断注入的 tracepoint 顺序不保证总是“IRQ -> sched_waking”。
# 当前 openEuler/KVM 上还会出现：
#
#   sched_waking -> sched_wakeup -> vgic_update_irq_pending -> sched_switch-in
#
# 因此唤醒原因必须在 sched_waking 前后双向匹配；只向前查找会把上述 IRQ
# 唤醒误报成 other。
#
# 四、单文件如何同时控制 guest
# ------------------------------------------------------------------------------
# 脚本内嵌了一个很小的 guest init。每次实验只把它注入临时 rootfs 副本，
# 不修改 base ext4。guest 启动后执行以下同步：
#
#   启动完成 -> 输出 FC_READY -> 等待宿主机发送 GO -> 执行 replay
#
# 宿主机侧的 perf 还会经过第二层同步：
#
#   perf 进程启动（事件禁用） -> enable 并等待 ack -> 发送 GO
#   target 输出 DONE          -> disable 并等待 ack -> 结束 perf
#   perf 完全停止             -> 导出 target replay 日志
#
# 因此 Firecracker boot、guest 初始化、git reset，以及 perf 初始化期间的
# READY 等待不会进入 perf.data。enable ack 到发送 GO 之间只保留记录起点和
# 写入串口 FIFO 两个必要操作，既把边界压到最小，也不会漏掉 replay 开头。
#
# 五、主要输出
# ------------------------------------------------------------------------------
#   summary.csv             调度、guest/Host 时间、阻塞/排队时间等汇总
#   switch_out_events.csv   每次调出、唤醒者、唤醒原因和后续调入的完整明细
#   wakeup_cause_summary.csv  本轮主动调出的唤醒原因计数与占比
#   perf.data               perf kvm stat record 产生的原始数据
#   perf.txt                perf script 转换后的文本
#   kvm-stat-report.txt     perf kvm stat report 的 target VM-exit 统计
#   threads.csv             各 Firecracker 宿主机线程及 TID
#   scheduling.csv          各线程的调度策略、实时优先级和 CPU 亲和性快照
#   replay.log              target workload 本轮 replay 的 stdout/stderr
#   *.console.log           各 microVM 的串口日志
#
# replay.log 的内容先写入 guest 内的 tmpfs；target 完成且 perf 停止后，才通过
# 串口传回宿主机。因此日志打印不会进入 perf.data。捕获 stdout/stderr 本身仍
# 会产生少量 guest 内存写入；若需要与旧版“输出丢弃”实验严格保持一致，可在
# 启动时设置 SAVE_REPLAY_LOG=0。
#
# ==============================================================================

set -Eeuo pipefail
export LC_ALL=C
shopt -u varredir_close 2>/dev/null || true
# 每次启动都会打印这个版本号和脚本的绝对路径。这样服务器上即使同时留有
# 多个同名副本，也能从实验日志直接确认真正执行的是哪一版。
SCRIPT_VERSION="2026-07-31-v17-cluster-noise"

log() { printf '[fc-exp] %s\n' "$*"; }
die() { printf '[fc-exp] ERROR: %s\n' "$*" >&2; exit 1; }
