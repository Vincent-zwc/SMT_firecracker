#!/usr/bin/env python3
"""把 batch_logs 下所有 run 的 summary.csv 合并成 Excel/CSV，方便 Excel 查看。

扫描 batch_logs/{baseline,noise}_*.log，提取每个 log 末尾的 "实验完成 run_dir=..."，
读取对应 run_dir/summary.csv，加上 type/workload/run_dir 列后合并。

输出:
  cluster_noise_summary_long.csv   长表（10 行，每行一个 run）
  cluster_noise_summary.xlsx       3 个 sheet:
    - raw_long       长表（全部 summary.csv 字段）
    - compare        baseline vs noise 并排对比 + wall_s delta%
    - batch_overview run_cluster_noise_batch.sh 的汇总表

依赖: pandas + openpyxl (生成 xlsx); 没装则降级只输出 csv。
安装: pip install pandas openpyxl
"""
import csv
import os
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent


def mode_from_dirname(d):
    # batch_logs        -> n5
    # batch_logs_n5     -> n5
    # batch_logs_n5_fifo-> n5_fifo
    name = d.name
    if name == "batch_logs":
        return "n5"
    return name.replace("batch_logs_", "", 1)


def parse_log_name(fname):
    m = re.match(r"(baseline|noise)_(.+)\.log$", fname)
    return (m.group(1), m.group(2)) if m else None


def extract_run_dir(log_path):
    rd = None
    with open(log_path, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            m = re.search(r"实验完成 run_dir=(\S+)", line)
            if m:
                rd = m.group(1)
    return rd


def read_summary(path):
    with open(path, "r", encoding="utf-8") as f:
        rows = list(csv.DictReader(f))
    return rows[0] if rows else {}


def collect_runs():
    runs = []
    # 扫所有 batch_logs* 目录(含旧的 batch_logs)
    for d in sorted(HERE.glob("batch_logs*")):
        if not d.is_dir():
            continue
        mode = mode_from_dirname(d)
        for log in sorted(d.glob("*.log")):
            info = parse_log_name(log.name)
            if not info:
                continue
            run_type, workload = info
            rd = extract_run_dir(log)
            if not rd or not os.path.isdir(rd):
                sys.stderr.write(f"WARN skip {log}: run_dir 不可用\n")
                continue
            sp = Path(rd) / "summary.csv"
            if not sp.exists():
                sys.stderr.write(f"WARN skip {log}: summary.csv 缺失\n")
                continue
            row = read_summary(sp)
            row["_mode"] = mode
            row["_type"] = run_type
            row["_workload"] = workload
            row["_run_dir"] = rd
            row["_run_dir_basename"] = os.path.basename(rd)
            runs.append(row)
    return runs


def write_csv(runs, path):
    lead = ["_mode", "_type", "_workload", "_run_dir_basename", "_run_dir"]
    seen = set(lead)
    fieldnames = list(lead)
    for r in runs:
        for k in r.keys():
            if k not in seen:
                fieldnames.append(k)
                seen.add(k)
    with open(path, "w", encoding="utf-8-sig", newline="") as f:
        w = csv.DictWriter(f, fieldnames=fieldnames, extrasaction="ignore")
        w.writeheader()
        for r in runs:
            w.writerow(r)


def write_xlsx(runs, path):
    import pandas as pd

    df = pd.DataFrame(runs)
    lead = ["_mode", "_type", "_workload", "_run_dir_basename", "_run_dir"]
    other = [c for c in df.columns if c not in lead]
    df = df[lead + other]
    for c in other:
        try:
            df[c] = pd.to_numeric(df[c])
        except (ValueError, TypeError):
            pass

    metrics = [
        "wall_s", "oncpu_s", "guest_running_s", "host_vcpu_running_s",
        "switch_out_total", "slice_avg_ms", "gap_avg_ms",
        "kvm_exit_per_guest_s", "voluntary_total", "passive_total",
        "target_kvm_exit", "wakeup_events_recorded",
    ]
    metrics = [m for m in metrics if m in df.columns]
    modes = sorted(df["_mode"].unique())

    with pd.ExcelWriter(path, engine="openpyxl") as w:
        # Sheet 1: 长表(含 mode 列)
        df.sort_values(["_workload", "_mode", "_type"]).to_excel(
            w, sheet_name="raw_long", index=False
        )

        # Sheet 2: 每 mode 一张 baseline vs noise 并排对比
        for mode in modes:
            sub = df[df["_mode"] == mode]
            if sub.empty:
                continue
            pivot = sub.pivot_table(
                index="_workload", columns="_type",
                values=metrics, aggfunc="first",
            )
            new_cols = []
            for m in metrics:
                if (m, "baseline") in pivot.columns:
                    new_cols.append((m, "baseline"))
                if (m, "noise") in pivot.columns:
                    new_cols.append((m, "noise"))
            pivot = pivot[new_cols]
            pivot.columns = [f"{m}_{t}" for m, t in pivot.columns]
            if "wall_s_baseline" in pivot.columns and "wall_s_noise" in pivot.columns:
                pivot["wall_s_delta_s"] = pivot["wall_s_noise"] - pivot["wall_s_baseline"]
                pivot["wall_s_delta_pct"] = 100 * pivot["wall_s_delta_s"] / pivot["wall_s_baseline"]
            sheet = f"compare_{mode}"[:31]  # excel sheet 名 <=31 字符
            pivot.reset_index().to_excel(w, sheet_name=sheet, index=False)

        # Sheet 3: 跨 mode 对比(n5 vs n5_fifo 的 wall_s 与 delta%)
        if len(modes) >= 2:
            cross = df.pivot_table(
                index="_workload", columns=["_mode", "_type"],
                values="wall_s", aggfunc="first",
            )
            cross.columns = [f"{m}_{t}" for m, t in cross.columns]
            cross.reset_index().to_excel(w, sheet_name="cross_mode_wall_s", index=False)

        # Sheet 4: 各 mode 的 batch 汇总表
        for mode in modes:
            batch_csv = HERE / f"cluster_noise_table_{mode}.csv"
            if not batch_csv.exists() and mode == "n5":
                batch_csv = HERE / "cluster_noise_table.csv"
            if batch_csv.exists():
                pd.read_csv(batch_csv).to_excel(
                    w, sheet=f"batch_{mode}"[:31], index=False
                )

        for ws in w.book.worksheets:
            for col in ws.columns:
                maxlen = max((len(str(c.value)) if c.value else 0) for c in col)
                ws.column_dimensions[col[0].column_letter].width = min(maxlen + 2, 50)
            ws.freeze_panes = "A2"


def main():
    runs = collect_runs()
    if not runs:
        sys.stderr.write("没有找到任何 run，先跑 run_cluster_noise_batch.sh\n")
        sys.exit(1)

    runs = sorted(runs, key=lambda r: (r["_workload"], r["_mode"], r["_type"]))

    csv_out = HERE / "cluster_noise_summary_long.csv"
    write_csv(runs, csv_out)
    print(f"长表 CSV: {csv_out}  ({len(runs)} 行)")

    try:
        import openpyxl  # noqa: F401
    except ImportError:
        print("openpyxl 未安装，仅输出 CSV。装: pip install openpyxl pandas")
        return

    xlsx_out = HERE / "cluster_noise_summary.xlsx"
    write_xlsx(runs, xlsx_out)
    modes = sorted({r["_mode"] for r in runs})
    print(f"Excel: {xlsx_out}  (含 mode: {','.join(modes)})")


if __name__ == "__main__":
    main()
