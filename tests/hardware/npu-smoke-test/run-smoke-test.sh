#!/usr/bin/env bash
# NPU smoke test runner — run ON THE TABLET from this directory.
# Captures evidence for hardware test matrix row 17 into ./evidence/.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EV="$HERE/evidence/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$EV"
MODEL="${1:-$HERE/mobilenet_v2_rk3562.rknn}"

echo "=== NPU smoke test (evidence -> $EV) ==="

echo "--- [1/5] driver state"
sudo cat /sys/kernel/debug/rknpu/version | tee "$EV/rknpu-version.txt"
ls /sys/class/devfreq/ff300000.npu >/dev/null 2>&1 \
  && echo "devfreq: present" | tee "$EV/devfreq.txt" \
  || echo "devfreq: MISSING (DT node disabled?)" | tee "$EV/devfreq.txt"
dmesg | grep -i rknpu | tail -5 | tee "$EV/dmesg-rknpu.txt"

echo "--- [2/5] runtime prerequisites"
if ! ldconfig -p | grep -q librknnrt; then
  echo "librknnrt not installed; install with:"
  echo "  sudo apt install ./librknnrt_2.3.2-1_arm64.deb"
fi
python3 -c "import rknnlite" 2>/dev/null || {
  echo "rknn-toolkit-lite2 missing; install with:"
  echo "  pip3 install --break-system-packages $HERE/rknn_toolkit_lite2-2.3.2-cp311-*.whl"
}

echo "--- [3/5] NPU load BEFORE (expect idle)"
sudo cat /sys/kernel/debug/rknpu/load | tee "$EV/load-before.txt"

echo "--- [4/5] inference (sampling load mid-run)"
( sleep 2; sudo cat /sys/kernel/debug/rknpu/load > "$EV/load-during.txt" 2>&1 ) &
python3 "$HERE/npu_smoke_test.py" "$MODEL" 50 | tee "$EV/smoke-test-output.txt"
RC=${PIPESTATUS[0]}
wait

echo "--- [5/5] NPU load DURING was:"
cat "$EV/load-during.txt"
sudo cat /sys/kernel/debug/rknpu/load > "$EV/load-after.txt"

echo ""
if [ "$RC" -eq 0 ]; then
  echo "RESULT: PASS (matrix row 17) — evidence in $EV"
  echo "Note load-before vs load-during: if identical under load, the"
  echo "'static NPU load' question (wiki 06 #1) is answered 'static'."
else
  echo "RESULT: FAIL (rc=$RC) — evidence in $EV"
fi
exit "$RC"
