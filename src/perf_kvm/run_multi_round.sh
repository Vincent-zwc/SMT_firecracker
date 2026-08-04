#!/usr/bin/env bash
# run_multi_round.sh -- 跑多轮 CFS + FIFO, 每轮独立目录, 跑完出 excel + 统计
# 用法: ./run_multi_round.sh [轮数, 默认3]
set -Eeuo pipefail
ROUNDS=${1:-3}

cd "$(dirname "${BASH_SOURCE[0]}")"

for r in $(seq 1 "$ROUNDS"); do
    echo "[$(date '+%F %T')] === CFS round $r/$ROUNDS ==="
    ROUND=$r ./run_cluster_noise_batch.sh
    mv cluster_noise_table_n5.csv "cluster_noise_table_n5_r${r}.csv"
    mv batch_logs_n5 "batch_logs_n5_r${r}"
done

for r in $(seq 1 "$ROUNDS"); do
    echo "[$(date '+%F %T')] === FIFO round $r/$ROUNDS ==="
    MODE=n5_fifo ROUND=$r ./run_cluster_noise_batch.sh
    mv cluster_noise_table_n5_fifo.csv "cluster_noise_table_n5_fifo_r${r}.csv"
    mv batch_logs_n5_fifo "batch_logs_n5_fifo_r${r}"
done

echo "[$(date '+%F %T')] 全部完成, 生成 excel..."
python3 export_to_excel.py

echo "[$(date '+%F %T')] 生成多轮统计..."
python3 stats_multi_round.py

echo "[$(date '+%F %T')] 收尾"
