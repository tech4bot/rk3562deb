#!/usr/bin/env bash
# Set up the RKNN model-conversion environment on Conrad (x86_64).
# Produces ~/venvs/rknn with rknn-toolkit2 2.3.2 and the dependency pins
# that are known to work (see tests/hardware/npu-smoke-test/README.md
# for why each pin exists).
set -euo pipefail

VENV="${1:-$HOME/venvs/rknn}"

python3 -m venv "$VENV"
"$VENV/bin/pip" install --upgrade pip
# Order matters: the toolkit's own resolver would pull too-new onnx/setuptools
"$VENV/bin/pip" install 'setuptools<81' 'onnx==1.16.1' 'numpy<=1.26.4' 'protobuf<=4.25.4'
"$VENV/bin/pip" install rknn-toolkit2==2.3.2

"$VENV/bin/python" - <<'EOF'
from rknn.api import RKNN
r = RKNN()
r.config(target_platform='rk3562', mean_values=[[0,0,0]], std_values=[[1,1,1]])
print("rknn-toolkit2 OK, rk3562 target accepted")
EOF

echo "Done. Activate with: source $VENV/bin/activate"
