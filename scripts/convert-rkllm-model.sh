#!/usr/bin/env bash
# Convert a HuggingFace LLM to a .rkllm for the RK3562 NPU (row 18 payload).
# Wraps convert_rkllm_model.py using the venv from setup-rkllm-conversion-env.sh.
#
# Usage: convert-rkllm-model.sh MODEL [QUANT_DTYPE] [OUTPUT]
#   MODEL        HuggingFace ID (e.g. Qwen/Qwen3-0.6B) or local model dir
#   QUANT_DTYPE  default w4a16_g64 (RK3562 supports: w8a8, w4a16_g32/g64/g128, w4a8_g32)
#   OUTPUT       default: tests/hardware/npu-smoke-test/<model>_<dtype>_rk3562.rkllm
#                (naming matches mobilenet_v2_rk3562.rknn there)
set -euo pipefail

VENV="${RKLLM_VENV:-$HOME/venvs/rkllm}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

MODEL="${1:?usage: convert-rkllm-model.sh MODEL [QUANT_DTYPE] [OUTPUT]}"
DTYPE="${2:-w4a16_g64}"

if [ ! -x "$VENV/bin/python" ]; then
    echo "ERROR: no venv at $VENV — run setup-rkllm-conversion-env.sh first." >&2
    exit 1
fi

if [ $# -ge 3 ]; then
    OUTPUT="$3"
else
    # Qwen/Qwen3-0.6B -> qwen3_0.6b_w4a16_g64_rk3562.rkllm
    NAME=$(basename "$MODEL" | tr '[:upper:]' '[:lower:]' | tr '-' '_')
    OUTPUT="$REPO_ROOT/tests/hardware/npu-smoke-test/${NAME}_${DTYPE}_rk3562.rkllm"
fi

exec "$VENV/bin/python" "$REPO_ROOT/scripts/convert_rkllm_model.py" \
    "$MODEL" "$OUTPUT" --quantized-dtype "$DTYPE"
