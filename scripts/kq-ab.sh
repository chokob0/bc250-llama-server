#!/usr/bin/env bash
# Interleaved A/B of K-quant mat-vec rows per workgroup (kq=2 upstream default vs kq=4 RDNA1 patch).
# Stops llama-server while it runs. Usage: sudo ./scripts/kq-ab.sh [model.gguf ...]
set -euo pipefail
LLAMA_DIR="${LLAMA_DIR:-/opt/llama.cpp}"
MODELS=("$@"); [ ${#MODELS[@]} -gt 0 ] || MODELS=(/models/Qwen3.5-9B-Q4_K_M.gguf /models/granite-4.0-h-tiny-Q4_K_M.gguf)
systemctl stop llama-server 2>/dev/null || true
trap 'systemctl start llama-server 2>/dev/null || true' EXIT
for m in "${MODELS[@]}"; do
  for round in 1 2; do for kq in 2 4; do
    sleep "${COOL:-30}"
    GGML_VK_RM_KQ=$kq GGML_VK_RM_IQ=4 "$LLAMA_DIR/build/bin/llama-bench" -m "$m" -ngl 99 -fa 1 -lm none \
      -p 0 -n 128 -r 10 -o jsonl 2>/dev/null \
      | jq -r --arg m "$(basename "$m")" --arg k $kq --arg r $round \
        '"\($m)  kq=\($k)  round \($r)  \(.avg_ts*100|round/100) ± \(.stddev_ts*100|round/100) tok/s"'
  done; done
done | tee "kq-ab-$(date +%Y%m%d-%H%M).txt"
