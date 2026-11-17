#!/usr/bin/env bash
# A/B sweep of the bc250 tuning knobs on a BC-250, without rebuilding.
# (Comentarios en español; ver docs/guia-es.md.)
#
# Uso:  ./scripts/bench-sweep.sh /ruta/modelo.gguf [decode|prefill|all]
#
# Cada punto se mide tras una pausa de enfriamiento y se anota el reloj de la GPU
# y la temperatura antes y después: una pasada con throttling parece una regresión
# y no lo es. Resultado: un .jsonl por punto y un resumen en ./bench-<fecha>/.
set -euo pipefail

MODEL="${1:?uso: $0 modelo.gguf [decode|prefill|all]}"
WHAT="${2:-all}"
LLAMA_DIR="${LLAMA_DIR:-/opt/llama.cpp}"
BIN="${BIN:-$LLAMA_DIR/build/bin/llama-bench}"
THREADS="${THREADS:-6}"
COOL="${COOL:-45}"          # segundos de pausa entre puntos
REPS="${REPS:-3}"
CTK="${CTK:-q8_0}"; CTV="${CTV:-q8_0}"
OUT="bench-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"

sclk() { { grep -h '\*' /sys/class/drm/card*/device/pp_dpm_sclk 2>/dev/null | head -1 | awk '{print $2}'; } || true; }
temp() {
    for f in /sys/class/drm/card*/device/hwmon/hwmon*/temp1_input; do
        [ -r "$f" ] && { echo "$(( $(cat "$f") / 1000 ))C"; return; }
    done; echo "?"
}

run() {  # run <etiqueta> <args de llama-bench...>   (las variables GGML_VK_* se heredan del entorno)
    local tag="$1"; shift
    sleep "$COOL"
    local c0 t0; c0=$(sclk); t0=$(temp)
    "$BIN" -m "$MODEL" -ngl 99 -fa on -lm none -t "$THREADS" -ctk "$CTK" -ctv "$CTV" \
        -r "$REPS" -o jsonl "$@" > "$OUT/$tag.jsonl" 2> "$OUT/$tag.log" || echo "  ($tag falló, ver $OUT/$tag.log)"
    local c1 t1; c1=$(sclk); t1=$(temp)
    python3 - "$OUT/$tag.jsonl" "$tag" "$c0→$c1" "$t0→$t1" <<'EOF' | tee -a "$OUT/resumen.txt"
import json, sys
path, tag, clk, tmp = sys.argv[1:5]
for line in open(path):
    line = line.strip()
    if not line.startswith("{"):
        continue
    r = json.loads(line)
    kind = "pp%d" % r["n_prompt"] if r.get("n_gen", 0) == 0 else "tg%d" % r["n_gen"]
    print("%-22s %-7s d=%-6s ub=%-5s %8.2f ± %-6.2f tok/s   reloj %s  temp %s" % (
        tag, kind, r.get("n_depth", 0), r.get("n_ubatch", "?"), r["avg_ts"], r["stddev_ts"], clk, tmp))
EOF
}

echo "modelo: $MODEL" | tee "$OUT/resumen.txt"
# llama-bench no tiene --version: el commit del fork sale en cada .jsonl (build_commit).
git -C "$LLAMA_DIR" log --oneline -1 2>/dev/null | tee -a "$OUT/resumen.txt" || true

if [ "$WHAT" = decode ] || [ "$WHAT" = all ]; then
    echo "== Generación (tg128): filas por workgroup ==" | tee -a "$OUT/resumen.txt"
    # Comportamiento de upstream en RDNA1: kq=2, iq=4.
    GGML_VK_RM_KQ=2 GGML_VK_RM_IQ=4 run tg-upstream-kq2-iq4 -p 0 -n 128
    # Valor por defecto del fork: kq=4, iq=4.
    run tg-fork-kq4-iq4 -p 0 -n 128
    # Lo que hacía el fork de TechMakesArt (kq=4 arrastraba iq=8) y un punto intermedio.
    GGML_VK_RM_IQ=8 run tg-kq4-iq8 -p 0 -n 128
    GGML_VK_RM_IQ=2 run tg-kq4-iq2 -p 0 -n 128
    echo "== Generación con contexto ocupado ==" | tee -a "$OUT/resumen.txt"
    run tg-fork-depth -p 0 -n 128 -d 4096,16384
fi

if [ "$WHAT" = prefill ] || [ "$WHAT" = all ]; then
    echo "== Prefill (pp2048) con y sin staging de K/V (PR #28507) ==" | tee -a "$OUT/resumen.txt"
    for d in 0 4096 8192 16384; do
        GGML_VK_FA_SHMEM_STAGING=0 run pp-staging0-d$d -p 2048 -n 0 -d $d
        GGML_VK_FA_SHMEM_STAGING=1 run pp-staging1-d$d -p 2048 -n 0 -d $d
    done
    echo "== Micro-lote ==" | tee -a "$OUT/resumen.txt"
    run pp-ubatch -p 2048 -n 0 -b 2048 -ub 512,1024,2048 -d 0,8192
fi

echo
echo "Resumen en $OUT/resumen.txt"
