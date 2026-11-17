#!/usr/bin/env bash
# Builds patched llama.cpp for the AMD BC-250 and installs llama-server as a systemd service.
# Tested on Fedora 43 (Mesa RADV) with the 40-CU unlock and cyan-skillfish-governor-smu.
#
#   sudo ./scripts/install.sh            # build + install service and config
#   sudo ./scripts/install.sh --build    # build only (no service, no config)
#
# Re-running is safe: it rebuilds and never overwrites an existing /etc/llama/models.ini or key.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# llama.cpp commit the patches in patches/ were rebased and tested on.
LLAMA_COMMIT="${LLAMA_COMMIT:-e8fbcad855c5d8c315aa1dde231836ae472f5779}"
LLAMA_DIR="${LLAMA_DIR:-/opt/llama.cpp}"
BUILD_ONLY=0
[ "${1:-}" = "--build" ] && BUILD_ONLY=1

[ "$(id -u)" -eq 0 ] || { echo "Run as root (sudo)."; exit 1; }

echo "== Dependencies"
dnf install -y git cmake ninja-build gcc gcc-c++ glslc \
    vulkan-headers vulkan-loader-devel spirv-headers-devel libcurl-devel jq >/dev/null

echo "== llama.cpp @ ${LLAMA_COMMIT:0:9} in $LLAMA_DIR"
if [ ! -d "$LLAMA_DIR/.git" ]; then
    git clone https://github.com/ggml-org/llama.cpp "$LLAMA_DIR"
fi
cd "$LLAMA_DIR"
git fetch -q origin
git checkout -q -B bc250 "$LLAMA_COMMIT"
git -c user.name=bc250 -c user.email=bc250@localhost am -q "$REPO_DIR"/patches/*.patch
git log --oneline -5

echo "== Build (GGML_NATIVE: the binary targets this board's Zen 2; do not copy it elsewhere)"
rm -rf build
cmake -B build -G Ninja -DCMAKE_BUILD_TYPE=Release \
    -DGGML_VULKAN=ON -DGGML_NATIVE=ON -DLLAMA_CURL=ON >/dev/null
cmake --build build -j"$(nproc)" --target llama-server llama-bench llama-completion test-backend-ops
./build/bin/llama-bench --list-devices 2>&1 | grep -i -E "vulkan|radv" || true

[ "$BUILD_ONLY" -eq 1 ] && exit 0

echo "== Service user, config and unit"
id llama >/dev/null 2>&1 || useradd --system --no-create-home --shell /sbin/nologin -G video,render llama
mkdir -p /etc/llama /models
[ -f /etc/llama/models.ini ] || install -m 644 "$REPO_DIR/config/models.ini" /etc/llama/models.ini
if [ ! -f /etc/llama/env ]; then
    echo "LLAMA_API_KEY=$(openssl rand -hex 24)" > /etc/llama/env
    chmod 640 /etc/llama/env; chgrp llama /etc/llama/env
fi
install -m 644 "$REPO_DIR/systemd/llama-server.service" /etc/systemd/system/llama-server.service
systemctl daemon-reload

if systemctl is-active -q ollama 2>/dev/null; then
    echo "Ollama is running: stop it first (systemctl disable --now ollama). Both cannot fit in 16 GB."
fi
if command -v firewall-cmd >/dev/null && ! firewall-cmd --list-ports | grep -q 8080/tcp; then
    firewall-cmd -q --permanent --add-port=8080/tcp && firewall-cmd -q --reload
fi

cat <<EOF

Done. Next:
  1. Put your GGUF files in /models and check the paths in /etc/llama/models.ini
  2. systemctl enable --now llama-server && journalctl -u llama-server -f
  3. API key (for Open WebUI, Home Assistant, n8n...): cat /etc/llama/env
EOF
