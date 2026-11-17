# bc250-llama-server

llama.cpp `llama-server` tuned for the **AMD BC-250** (Cyan Skillfish, gfx1013, 16 GB unified GDDR6):
four small Vulkan patches, router presets, a systemd service and the benchmarks behind every setting.

On one board with **all 40 CU unlocked** and the GPU at 1500 MHz, with Qwen3.6-35B-A3B UD-IQ2_M
(both columns measured on the same unlocked board):

| | Ollama | This setup |
|---|---|---|
| Generation (server, 400-token answers) | 48.6 tok/s | **83.0 tok/s** |
| Prefill (2K-token prompt) | ~125 tok/s | **946 tok/s** |
| First answer after a reboot | ~20 s (model load) | **0.9 s** (model resident) |

> [!IMPORTANT]
> **These numbers require the 40-CU unlock.** Out of the box the BC-250 runs with 24 of its
> 40 compute units enabled; on a stock board expect roughly a quarter less generation speed and
> a third less prefill (the community measured +32 % generation and +50 % prefill from the
> unlock). The unlock is not part of this repository: see the BC-250 community guides.
> Check how many you have before comparing:
>
> ```bash
> vulkaninfo 2>/dev/null | grep -E 'shaderEngineCount|shaderArraysPerEngineCount|computeUnitsPerShaderArray'
> # 40 CU = 2 x 2 x 10   |   24 CU (stock) = 2 x 2 x 6
> ```

Full numbers and method: [`results/`](results/).

## What makes the difference

Most of the gain is configuration, not code:

1. **llama-server instead of Ollama**, all layers on the GPU, flash attention, q8_0 KV cache.
2. **`ubatch-size = 2048`**: prefill 650 → 946 tok/s (+45 %).
3. **`backend-sampling = true`**: sampling on the GPU, 79.6 → 83.0 tok/s in the server.
4. **Context checkpoints** for hybrid models (Qwen3.5/3.6): a long system prompt is not
   reprocessed every turn (4.1 s → 0.3 s).
5. **`load-on-startup` and no idle sleep**: the main model stays in memory.
6. **Always pass `-c` in manual tests.** Without it llama.cpp allocates the model's full
   262K context (~5 GB of KV) and the kernel OOM-kills it silently (`Killed`, exit 137):
   the board reports 16.5 GB free while ~14 GB really are.

The patches add a few more percent and the knobs to measure them:

| Patch | Origin | Effect on the BC-250 |
|---|---|---|
| `0001` 4 rows per workgroup for K-quant mat-vec on RDNA1 | TechMakesArt/llama.cpp-bc250, reworked | +1 % tg on IQ2_M (noise); being measured on Q4_K_M with `scripts/kq-ab.sh` |
| `0002` K/V shared-memory staging in scalar FA on RDNA | llama.cpp PR #28507 (Melon_USK), unmerged | +0.3 to +1.6 % prefill on Qwen3.6; +12–50 % reported on Gemma 4 |
| `0003` Q4_K `smin` algebraic restructure | TechMakesArt/llama.cpp-bc250 | Q4_K models only |
| `0004` runtime knobs `GGML_VK_RM_STDQ/KQ/IQ`, `GGML_VK_FA_SHMEM_STAGING` | this repo | A/B testing without rebuilding |

Patches apply on llama.cpp `e8fbcad85` (16 Nov 2026), which already includes the upstream
fix that drops K/V staging when it does not fit in shared memory (#32244).

## Requirements

- BC-250 with the **40-CU unlock** (+32 % generation, +50 % prefill vs 24 CU).
- A GPU governor such as `cyan-skillfish-governor-smu`, capped at 1500 MHz to start
  (higher clocks need extra cooling, including the GDDR6 on the back of the board).
- Mesa RADV recent enough for flash attention (25.1+); tested on 25.3.6.
- Fedora (the script uses `dnf`); other distros need the same packages.
- Headless boot recommended (`systemctl set-default multi-user.target`): every MB counts.

## Install

```bash
git clone https://github.com/chokob0/bc250-llama-server && cd bc250-llama-server
sudo ./scripts/install.sh
# copy your GGUFs to /models, check paths in /etc/llama/models.ini, then:
sudo systemctl enable --now llama-server
cat /etc/llama/env        # API key for clients
```

Clients use the OpenAI API at `http://<board>:8080/v1` with that key and pick a preset with
`"model": "qwen36-moe"` (or `gpt-oss-20b`, `qwen35-9b`, `granite-tiny`). Tested with
Open WebUI, Home Assistant (native llama.cpp integration, 2026.8+) and n8n.

Only one model fits at a time: asking for another preset unloads the resident one
(~20 s to swap back).

## Verify on your board

```bash
cd /opt/llama.cpp
./build/bin/test-backend-ops test -b Vulkan0 -o MUL_MAT,MUL_MAT_ID
./build/bin/test-backend-ops test -b Vulkan0 -o FLASH_ATTN_EXT
# both must end with "2/2 backends passed"

./build/bin/llama-completion -m /models/<model>.gguf -c 4096 -ngl 99 -fa on -lm none \
  -no-cnv -n 8 -p "Hello" -v 2>&1 | grep -E 'rows per workgroup|offloaded'
# expected: "stdq=1 kq=4 iq=4" and "offloaded N/N layers to GPU"

sudo ./scripts/bench-sweep.sh /models/<model>.gguf decode    # and: prefill
```

## Repository

```
patches/      llama.cpp patches (git am)
scripts/      install.sh, bench-sweep.sh, kq-ab.sh
config/       models.ini (router presets, every value commented with its measurement)
systemd/      llama-server.service
results/      benchmark logs
docs/         guia-es.md: full step-by-step guide in Spanish, with troubleshooting
```

## Credits

TechMakesArt/llama.cpp-bc250 (rm_kq and Q4_K work), Melon_USK (PR #28507),
akandr/bc250-rocm (reference numbers), the BC-250 community guides, and ggml-org.

## License

MIT, same as llama.cpp.
