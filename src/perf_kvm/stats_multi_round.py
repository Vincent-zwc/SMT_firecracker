#!/usr/bin/env python3
"""多轮实验统计: 扫描所有 batch_logs* 目录, 从每个 run_dir/summary.csv 读关键指标,
按 (mode, type, workload) 分组算 mean +/- stddev, 输出 CSV + 打印对比表。

支持的目录命名: batch_logs / batch_logs_n5 / batch_logs_n5_r1 / batch_logs_n5_fifo_r2 等
"""
import csv
import os
import re
import statistics
from collections import defaultdict
from pathlib import Path

HERE = Path(__file__).resolve().parent

METRICS = [
    "wall_s", "oncpu_s", "slice_avg_ms", "gap_avg_ms",
    "passive_total", "switch_out_total",
    "guest_running_s", "host_vcpu_running_s",
    "kvm_exit_per_guest_s",
]
DERIVED = ["oncpu_pct"]


def mode_from_dirname(d):
    name = d.name
    if name == "batch_logs":
        return "n5"
    name = re.sub(r"_r\d+$", "", name)
    return name.replace("batch_logs_", "", 1)


def extract_run_dir(log_path):
    rd = None
    with open(log_path, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            m = re.search(r"实验完成 run_dir=(\S+)", line)
            if m:
                rd = m.group(1)
    return rd


def collect():
    runs = []
    for d in sorted(HERE.glob("batch_logs*")):
        if not d.is_dir():
            continue
        mode = mode_from_dirname(d)
        for log in sorted(d.glob("*.log")):
            m = re.match(r"(baseline|noise)_(.+)\.log$", log.name)
            if not m:
                continue
            rtype, wl = m.group(1), m.group(2)
            rd = extract_run_dir(log)
            if not rd or not os.path.isdir(rd):
                continue
            sp = Path(rd) / "summary.csv"
            if not sp.exists():
                continue
            with open(sp, encoding="utf-8") as f:
                rows = list(csv.DictReader(f))
            if not rows:
                continue
            row = rows[0]
            vals = {}
            for met in METRICS:
                try:
                    vals[met] = float(row.get(met, ""))
                except (ValueError, TypeError):
                    pass
            if "wall_s" in vals and "oncpu_s" in vals and vals["wall_s"] > 0:
                vals["oncpu_pct"] = 100 * vals["oncpu_s"] / vals["wall_s"]
            runs.append((mode, rtype, wl, row.get("round", ""), vals))
    return runs


def main():
    runs = collect()
    if not runs:
        print("没有数据, 先跑 run_multi_round.sh")
        return

    groups = defaultdict(list)
    for mode, rtype, wl, rnd, vals in runs:
        groups[(mode, rtype, wl)].append(vals)

    all_metrics = METRICS + DERIVED
    out = HERE / "multi_round_stats.csv"
    with open(out, "w", encoding="utf-8-sig", newline="") as f:
        w = csv.writer(f)
        w.writerow(["mode", "type", "workload", "n"]
                    + [f"{m}_mean" for m in all_metrics]
                    + [f"{m}_sd" for m in all_metrics])
        for (mode, rtype, wl), vlist in sorted(groups.items()):
            n = len(vlist)
            row = [mode, rtype, wl, n]
            means = []
            sds = []
            for m in all_metrics:
                vals = [v[m] for v in vlist if m in v]
                if vals:
                    means.append(f"{statistics.mean(vals):.6f}")
                    sds.append(f"{statistics.pstdev(vals):.6f}" if len(vals) >= 2 else "0")
                else:
                    means.append("")
                    sds.append("")
            w.writerow(row + means + sds)
    print(f"统计 CSV: {out}  ({len(groups)} 组)")

    print(f"\n{'workload':<38} {'metric':<14} {'CFS_base':>16} {'CFS_noise':>16} {'FIFO_base':>17} {'FIFO_noise':>16}")
    print("-" * 118)
    workloads = sorted({wl for (_, _, wl) in groups.keys()})
    for wl in workloads:
        for m in ["wall_s", "oncpu_s", "oncpu_pct", "slice_avg_ms", "gap_avg_ms",
                  "passive_total", "switch_out_total", "kvm_exit_per_guest_s"]:
            cells = []
            for mode in ["n5", "n5_fifo"]:
                for rtype in ["baseline", "noise"]:
                    vlist = groups.get((mode, rtype, wl), [])
                    vals = [v[m] for v in vlist if m in v]
                    if vals:
                        if len(vals) >= 2:
                            cells.append(f"{statistics.mean(vals):.2f}±{statistics.pstdev(vals):.2f}")
                        else:
                            cells.append(f"{vals[0]:.2f}")
                    else:
                        cells.append("N/A")
            print(f"{wl:<38} {m:<14} {cells[0]:>16} {cells[1]:>16} {cells[2]:>17} {cells[3]:>16}")
        print()


if __name__ == "__main__":
    main()
