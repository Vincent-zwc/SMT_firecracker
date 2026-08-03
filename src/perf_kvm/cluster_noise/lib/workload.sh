# workload.sh -- sourced by fc_sched_experiment.sh; do not run directly. (split from v17 cluster-noise)

# workload 配置表，每行五列，以“|”分隔：
#   workload 名称 | base ext4 | guest 内仓库路径 | 固定 commit | replay 脚本
#
# ext4 使用相对路径时，相对于 IMAGE_DIR；也可以填写绝对路径。
# 新增或替换 workload 只修改这里，不需要修改后面的启动逻辑。
workload_table() {
    cat <<'TABLE'
SpikeInterface__spikeinterface-1057|base-spikeinterface.ext4|/workspace/SpikeInterface__spikeinterface__0.96|7268ab900443ca3f0239de3007352d05f2d7d875|/generated_replay.sh
12rambau__sepal_ui-747|base-12rambau.ext4|/workspace/12rambau__sepal_ui__2.15|a683a7665a9710acd5ca939308e18539e92014b7|/generated_replay.sh
abhinavsingh__proxy.py-740|base-abhinavsingh.ext4|/workspace/abhinavsingh__proxy.py__2.3|8052c907e8ed7bd889a13c8029a657675d6fd13a|/generated_replay.sh
mathandy__svgpathtools-170|base-mathandy.ext4|/workspace/mathandy__svgpathtools__1.4|c84c897bf2121ed86ceed45b4e027785351c2fd5|/generated_replay.sh
joke2k__faker-2007|base-joke2k.ext4|/workspace/joke2k__faker__24.2|250fa19baf01aa2289afe44b07225f785cf536c5|/generated_replay.sh
TABLE
}

# 把 workload_table 转换成 Bash 数组，后续代码即可按名称查询配置。
load_workload_table() {
    local name image repo commit replay extra
    while IFS='|' read -r name image repo commit replay extra; do
        [[ -n $name ]] || continue
        [[ -n $image && -n $repo && -n $commit && -n $replay && -z ${extra:-} ]] || \
            die "workload 配置行格式错误: $name"
        [[ $name =~ ^[A-Za-z0-9_.-]+$ ]] || die "workload 名称含不安全字符: $name"
        [[ $repo != *[[:space:]]* && $commit != *[[:space:]]* && $replay != *[[:space:]]* ]] || \
            die "guest 路径或 commit 不能包含空白字符: $name"
        [[ $image == /* ]] || image="$IMAGE_DIR/$image"
        ALL_WORKLOADS+=("$name")
        ROOTFS_OF[$name]=$image GUEST_REPO_OF[$name]=$repo COMMIT_OF[$name]=$commit REPLAY_OF[$name]=$replay
    done < <(workload_table)
}

# 决定本轮 VM 组成：target 固定为下标 0；N=5 时再取前 CORE0_BG 个非 target
# 作为核0 background。CORE0_BG 可配，默认 4（原 n5）；设 3 即"3背景1测试"。
select_case_workloads() {
    local name added=0
    [[ -n ${ROOTFS_OF[$TARGET_WORKLOAD]+yes} ]] || \
        die "workload 配置表中没有 target: $TARGET_WORKLOAD"
    CASE_WORKLOADS=("$TARGET_WORKLOAD")
    if is_five_vm_mode; then
        [[ $CORE0_BG =~ ^[1-9][0-9]*$ ]] || die "CORE0_BG 必须是正整数"
        for name in "${ALL_WORKLOADS[@]}"; do
            (( added < CORE0_BG )) || break
            [[ $name != "$TARGET_WORKLOAD" ]] && { CASE_WORKLOADS+=("$name"); added=$((added+1)); }
        done
        (( added == CORE0_BG )) || \
            die "核0 background 数量不足：需要 CORE0_BG=$CORE0_BG，实际可选 $added"
        ((${#CASE_WORKLOADS[@]} >= 2)) || die "N=5 至少需要 1 个 background"
    fi
}
