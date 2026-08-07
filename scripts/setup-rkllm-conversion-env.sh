#!/usr/bin/env bash
# Set up the RKLLM model-conversion environment on Conrad (x86_64).
# Produces ~/venvs/rkllm with rkllm-toolkit 1.3.0 (from airockchip/rknn-llm
# release-v1.3.0) and its pinned dependencies, using CPU-only torch wheels
# so we don't pull ~10 GB of CUDA libraries we can't use.
#
# Companion to setup-rknn-conversion-env.sh (vision models); this one is for
# LLM conversion targeting librkllmrt 1.3.0 on the device (RK3562).
set -euo pipefail

VENV="${1:-$HOME/venvs/rkllm}"
WHEEL_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/rkllm-toolkit"
WHEEL="rkllm_toolkit-1.3.0-cp312-cp312-linux_x86_64.whl"
WHEEL_URL="https://raw.githubusercontent.com/airockchip/rknn-llm/release-v1.3.0/rkllm-toolkit/packages/$WHEEL"

# The wheel is cp312-only; Ubuntu 24.04's python3 is 3.12.
PYVER=$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])')
if [ "$PYVER" != "3.12" ]; then
    echo "ERROR: python3 is $PYVER, but the rkllm-toolkit wheel needs 3.12 (cp312)." >&2
    exit 1
fi

# The pinned torch stack + transformers is multi-GB even CPU-only.
AVAIL_GB=$(df --output=avail -BG "$HOME" | tail -1 | tr -dc '0-9')
if [ "$AVAIL_GB" -lt 15 ]; then
    echo "ERROR: only ${AVAIL_GB} GB free on \$HOME; need ~15 GB for the conversion env." >&2
    exit 1
fi

mkdir -p "$WHEEL_CACHE"
if [ ! -f "$WHEEL_CACHE/$WHEEL" ]; then
    echo "Downloading $WHEEL ..."
    curl -fL -o "$WHEEL_CACHE/$WHEEL.tmp" "$WHEEL_URL"
    mv "$WHEEL_CACHE/$WHEEL.tmp" "$WHEEL_CACHE/$WHEEL"
fi

python3 -m venv "$VENV"
"$VENV/bin/pip" install --upgrade pip

# Order matters:
# 1. setuptools/wheel: py3.12 venvs don't ship setuptools, and auto_gptq
#    builds from sdist below with --no-build-isolation.
"$VENV/bin/pip" install setuptools wheel
# 2. torch/torchvision from the CPU index, at the toolkit's exact pins.
#    2.6.0+cpu satisfies the wheel's torch==2.6.0 pin (PEP 440 local-version
#    rules), so the rkllm install won't re-pull CUDA builds from PyPI.
"$VENV/bin/pip" install --index-url https://download.pytorch.org/whl/cpu \
    'torch==2.6.0' 'torchvision==0.21.0'
# 3. auto_gptq 0.7.1 has no cp312 wheel; build the sdist against the torch
#    we just installed, with the CUDA extension disabled.
BUILD_CUDA_EXT=0 "$VENV/bin/pip" install --no-build-isolation 'auto_gptq==0.7.1'
# 4. The toolkit itself; remaining pinned deps come from PyPI.
"$VENV/bin/pip" install "$WHEEL_CACHE/$WHEEL"

"$VENV/bin/python" - <<'EOF'
from importlib.metadata import version
from rkllm.api import RKLLM
RKLLM()
print(f"rkllm-toolkit {version('rkllm-toolkit')} OK, RKLLM() instantiates "
      f"(torch {version('torch')}, transformers {version('transformers')})")
EOF

echo "Done. Activate with: source $VENV/bin/activate"
