# guest.sh -- sourced by fc_sched_experiment.sh; do not run directly. (split from v17 cluster-noise)

# ============================ 内嵌 guest init ================================

write_guest_init() {
    local output=$1
    cat >"$output" <<'GUEST_INIT'
#!/bin/bash
# 这段脚本在 guest 内作为 PID 1 运行。
# 它只负责三件事：准备最小运行环境、等待宿主机 GO、按角色执行 replay。
#
# 不在 PID 1 上启用 nounset（set -u）。各 workload 镜像中的 Conda 版本并不
# 完全相同，部分 conda.sh 会有意读取尚未设置的变量；若 PID 1 开着 nounset，
# 这种兼容性差异会直接结束 init，随后内核只能报“Attempted to kill init”。
# 下面已经逐一校验了所有必需的 fc_* 参数，因此关闭 nounset 不会掩盖参数缺失。
set +u

# PID 1 启动时需要手动挂载这些伪文件系统，否则 git、进程查询和串口等
# 基础功能可能无法正常工作。
mount -t proc proc /proc 2>/dev/null || true
mount -t sysfs sysfs /sys 2>/dev/null || true
mount -t devtmpfs devtmpfs /dev 2>/dev/null || true
mkdir -p /dev/pts /run /tmp
mount -t devpts devpts /dev/pts 2>/dev/null || true

# 将标准输入、输出和错误全部接到 Firecracker 串口：
#   guest 用 echo 向宿主机报告状态；
#   宿主机通过串口输入 FIFO 发送 GO。
exec </dev/ttyS0 >/dev/ttyS0 2>&1

# 从 /proc/cmdline 中读取宿主机通过 boot_args 传进来的 fc_* 参数。
boot_value() {
    local key=$1 item
    for item in $(cat /proc/cmdline); do
        case $item in "$key"=*) printf '%s\n' "${item#*=}"; return ;; esac
    done
    return 1
}

ROLE=$(boot_value fc_role || true)
NAME=$(boot_value fc_name || true)
REPO=$(boot_value fc_repo || true)
COMMIT=$(boot_value fc_commit || true)
REPLAY=$(boot_value fc_replay || true)
SAVE_REPLAY_LOG=$(boot_value fc_save_replay_log || true)
REPLAY_LOG_MIB=$(boot_value fc_replay_log_mib || true)

# 出错后不直接退出 PID 1，避免内核 panic 淹没真正错误；串口会保留
# FC_ERROR，宿主机最终因等待 READY 超时而停止本轮实验。
fail() {
    echo "FC_ERROR role=${ROLE:-unknown} name=${NAME:-unknown} message=$*"
    while true; do sleep 3600; done
}

[[ $ROLE == target || $ROLE == background ]] || fail invalid_role
[[ -d $REPO/.git ]] || fail "repo_not_found:$REPO"
[[ -f $REPLAY ]] || fail "replay_not_found:$REPLAY"
[[ $SAVE_REPLAY_LOG == 0 || $SAVE_REPLAY_LOG == 1 ]] || fail invalid_save_replay_log
[[ $REPLAY_LOG_MIB =~ ^[1-9][0-9]*$ ]] || fail invalid_replay_log_mib

# 只为 target 创建日志 tmpfs。background 会无限循环 replay，保存其完整输出
# 会让日志无界增长，因此 background 始终保持静默。
TARGET_REPLAY_LOG=/run/fc-exp/replay.log
if [[ $ROLE == target && $SAVE_REPLAY_LOG == 1 ]]; then
    mkdir -p /run/fc-exp
    mount -t tmpfs -o "size=${REPLAY_LOG_MIB}m,mode=0700" \
        fc-replay-log /run/fc-exp 2>/dev/null || fail replay_log_tmpfs_mount_failed
fi

# 尽量复现 workload 镜像中的 Python/Conda 执行环境。
export HOME=/root USER=root LOGNAME=root SHELL=/bin/bash
export PATH=/opt/miniconda3/envs/testbed/bin:/opt/miniconda3/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PYTHONUNBUFFERED=1 PIP_BREAK_SYSTEM_PACKAGES=1
if [[ -f /opt/miniconda3/etc/profile.d/conda.sh ]]; then
    # PATH 已经显式指向 testbed 环境，所以 activate 失败时仍可继续执行。
    # 不再吞掉失败：把一条简短告警留在串口日志中，便于区分环境差异。
    source /opt/miniconda3/etc/profile.d/conda.sh >/dev/null 2>&1 || \
        echo "FC_WARNING role=$ROLE name=$NAME message=conda_source_failed"
    conda activate testbed >/dev/null 2>&1 || \
        echo "FC_WARNING role=$ROLE name=$NAME message=conda_activate_failed"
fi

reset_repo() { git -C "$REPO" reset --hard "$COMMIT" >/dev/null 2>&1; }

# background 无限循环，继续丢弃 stdout/stderr。
run_replay_silent() {
    (cd "$REPO" && /bin/bash "$REPLAY") </dev/null >/dev/null 2>&1
}

# target 仅执行一次。启用日志时先写到 guest tmpfs，不在测量窗口内打印串口。
run_target_replay() {
    if [[ $SAVE_REPLAY_LOG == 1 ]]; then
        (cd "$REPO" && /bin/bash "$REPLAY") \
            </dev/null >"$TARGET_REPLAY_LOG" 2>&1
    else
        run_replay_silent
    fi
}

# 在报告 READY 前恢复到固定 commit。因此 target 的 git reset 不会被
# 计入 perf 测量窗口；background 每轮结束后也会恢复相同初始状态。
reset_repo || fail reset_failed
echo "FC_READY role=$ROLE name=$NAME"

# 此处阻塞是实验同步屏障。只有宿主机确认绑核、背景预热和 perf 就绪后，
# 才会向对应 VM 写入 GO。
IFS= read -r command
[[ $command == GO ]] || fail expected_GO

if [[ $ROLE == background ]]; then
    # background VM 只启动一次，随后在同一个 guest 内循环 replay。
    # 不在宿主机反复重启 VM，避免把 boot/销毁开销混入背景噪声。
    echo "FC_BACKGROUND_STARTED name=$NAME"
    while true; do
        run_replay_silent || true
        reset_repo || fail reset_failed
    done
fi

# target 只执行一次。BEGIN/DONE 是宿主机确定采集窗口和返回码的标记。
echo "FC_TARGET_BEGIN name=$NAME"
run_target_replay
rc=$?
echo "FC_TARGET_DONE name=$NAME rc=$rc"

# DONE 后绝不执行第二轮 replay。启用日志时，宿主机会先停止 perf，再发送
# DUMP_REPLAY_LOG；此后才把日志打印到串口，所以日志传输不会进入 perf.data。
if [[ $SAVE_REPLAY_LOG == 1 ]]; then
    IFS= read -r command || true
    [[ $command == DUMP_REPLAY_LOG ]] || fail expected_DUMP_REPLAY_LOG

    echo "FC_REPLAY_LOG_BEGIN name=$NAME"
    cat "$TARGET_REPLAY_LOG"
    # replay 输出不一定以换行结束，先补一个换行，保证 END 标记单独成行。
    printf '\nFC_REPLAY_LOG_END name=%s\n' "$NAME"
else
    IFS= read -r _ || true
fi

# 日志导出后继续阻塞，等待宿主机终止 Firecracker。
while true; do sleep 3600; done
GUEST_INIT
    chmod 0755 "$output"
}

# 将本文件内嵌的 guest init 写入“临时 rootfs 副本”。
# debugfs 可以离线修改 ext4，因此不需要 mount，也不会碰原始 base ext4。
install_guest_init() {
    local rootfs_copy=$1 guest_init_source=$2 debugfs_log=$3

    # 若镜像里恰好已有同名文件，先删除；这里操作的仍然只是临时副本。
    debugfs -w -R 'rm /fc-exp-init.sh' "$rootfs_copy" >>"$debugfs_log" 2>&1 || true
    debugfs -w -R "write $guest_init_source /fc-exp-init.sh" \
        "$rootfs_copy" >>"$debugfs_log" 2>&1
    debugfs -w -R 'set_inode_field /fc-exp-init.sh mode 0100755' \
        "$rootfs_copy" >>"$debugfs_log" 2>&1

    # 写完马上验证执行位；否则 VM 能启动，但内核无法执行 init，错误不直观。
    debugfs -R 'stat /fc-exp-init.sh' "$rootfs_copy" 2>>"$debugfs_log" |
        grep -q 'Mode:.*0755' || die "guest init 注入失败: $rootfs_copy"
}

# 为一台 microVM 生成 Firecracker JSON 配置。
# 实验固定 vcpu_count=1：N=5 表示五台 1-vCPU 沙箱共享一个宿主机 CPU，
# 不是在一台 VM 内创建五个 vCPU。
write_firecracker_config() {
    local config_file=$1 rootfs_copy=$2 kernel_boot_args=$3

    # 下面直接把路径放入 JSON 字符串，因此显式拒绝未转义的双引号。
    [[ $KERNEL_IMAGE$rootfs_copy$kernel_boot_args != *'"'* ]] || \
        die "kernel、rootfs 或 boot_args 中不能包含双引号"

    cat >"$config_file" <<EOF
{
  "boot-source": {
    "kernel_image_path": "$(readlink -f "$KERNEL_IMAGE")",
    "boot_args": "$kernel_boot_args"
  },
  "drives": [{
    "drive_id": "rootfs",
    "path_on_host": "$(readlink -f "$rootfs_copy")",
    "is_root_device": true,
    "is_read_only": false
  }],
  "machine-config": {"vcpu_count": 1, "mem_size_mib": $MEM_MIB}
}
EOF
}
