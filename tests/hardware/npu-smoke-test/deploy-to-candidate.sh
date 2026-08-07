#!/usr/bin/env bash
# deploy-to-candidate.sh — Conrad-side deployer for session-001 NPU rows 17-18.
#
# Pushes everything the SD-booted candidate image needs (fresh rootfs: nothing
# from the stock eMMC system exists there) and installs the runtime debs:
#   - librknnrt_2.3.2-1_arm64.deb   (row 17: RKNN runtime)
#   - librkllmrt_1.3.0-2_arm64.deb  (row 18: RKLLM runtime + /usr/bin/llm_demo)
#   - qwen3_0.6b_w4a16_g64_rk3562.rkllm (751 MiB model — staged under ~ on the
#     device, NEVER /tmp: on-device /tmp is a 512 MiB tmpfs)
#   - MobileNetV2 .rknn + rknnlite wheel + smoke-test scripts
#
# Usage:   ./deploy-to-candidate.sh <tablet-ip> [remote-user]
# Example: ./deploy-to-candidate.sh 192.168.11.167
# (IP is DHCP-assigned and may differ after SD boot — check the router or
#  serial console.)
#
# Idempotent: rsync skips unchanged files (scp fallback skips on size match);
# dpkg -i re-installs harmlessly. Safe to re-run after a partial transfer.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"

IP="${1:?usage: $0 <tablet-ip> [remote-user]}"
RUSER="${2:-frodo}"
T="$RUSER@$IP"
RDIR="npu-smoke-test"          # relative to remote $HOME
SSH_OPTS=(-o ConnectTimeout=10)

DEB_RKNN="$REPO/debs/librknnrt_2.3.2-1_arm64.deb"
DEB_RKLLM="$REPO/debs/librkllmrt_1.3.0-2_arm64.deb"
PAYLOAD=(
  "$DEB_RKNN"
  "$DEB_RKLLM"
  "$HERE/run-candidate-smoke.sh"
  "$HERE/npu_smoke_test.py"
  "$HERE/mobilenet_v2_rk3562.rknn"
  "$HERE/rknn_toolkit_lite2-2.3.2-cp311-cp311-manylinux_2_17_aarch64.manylinux2014_aarch64.whl"
  "$HERE/qwen3_0.6b_w4a16_g64_rk3562.rkllm"
)

echo "=== [0/5] local payload check"
missing=0
for f in "${PAYLOAD[@]}"; do
  if [ -f "$f" ]; then
    printf '  %-60s %s\n' "$(basename "$f")" "$(stat -c%s "$f") bytes"
  else
    echo "  MISSING: $f"
    missing=1
  fi
done
if [ "$missing" -ne 0 ]; then
  echo "FATAL: payload incomplete. The .rkllm model is gitignored — regenerate"
  echo "with scripts/convert-rkllm-model.sh Qwen/Qwen3-0.6B w4a16_g64 if absent."
  exit 1
fi

echo "=== [1/5] connectivity ($T)"
ssh "${SSH_OPTS[@]}" "$T" 'echo "connected: $(hostname) | $(uname -r) | $(. /etc/os-release && echo "$PRETTY_NAME")"' \
  || { echo "FATAL: cannot ssh to $T (DHCP IP changed? candidate not booted?)"; exit 1; }

echo "=== [2/5] copy payload -> $T:~/$RDIR/  (model is 751 MiB — first copy takes a while)"
ssh "${SSH_OPTS[@]}" "$T" "mkdir -p ~/$RDIR ~/validation"
if command -v rsync >/dev/null && ssh "${SSH_OPTS[@]}" "$T" 'command -v rsync >/dev/null'; then
  rsync -a --info=progress2 "${PAYLOAD[@]}" "$T:$RDIR/"
else
  echo "  (rsync unavailable on one end — scp fallback, skipping size-identical files)"
  for f in "${PAYLOAD[@]}"; do
    base="$(basename "$f")"
    lsz="$(stat -c%s "$f")"
    rsz="$(ssh "${SSH_OPTS[@]}" "$T" "stat -c%s ~/$RDIR/$base 2>/dev/null || echo -1")"
    if [ "$lsz" = "$rsz" ]; then
      echo "  skip (same size): $base"
    else
      scp "$f" "$T:$RDIR/" || exit 1
    fi
  done
fi
ssh "${SSH_OPTS[@]}" "$T" "chmod +x ~/$RDIR/run-candidate-smoke.sh"

echo "=== [3/5] install runtime debs (sudo may prompt on the tty)"
ssh -t "${SSH_OPTS[@]}" "$T" "sudo dpkg -i ~/$RDIR/$(basename "$DEB_RKNN") ~/$RDIR/$(basename "$DEB_RKLLM") && sudo ldconfig" \
  || { echo "FATAL: dpkg -i failed"; exit 1; }

echo "=== [4/5] python prerequisites for row 17 rknnlite inference (best effort; needs device network)"
# Wheel deps are numpy/psutil/ruamel.yaml — take them from apt so pip only has
# to place the (pure local) wheel itself, no PyPI fetch of the wheel needed.
ssh -t "${SSH_OPTS[@]}" "$T" '
  set -x
  command -v pip3 >/dev/null || sudo apt-get install -y python3-pip
  sudo apt-get install -y python3-numpy python3-psutil python3-ruamel.yaml || true
  python3 -c "import rknnlite" 2>/dev/null || \
    pip3 install --break-system-packages --no-deps ~/'"$RDIR"'/rknn_toolkit_lite2-2.3.2-cp311-*.whl
' || echo "WARN: python setup incomplete — row 17 will degrade to driver-probe + librknnrt-presence (see run-candidate-smoke.sh)"

echo "=== [5/5] verify placement"
ssh "${SSH_OPTS[@]}" "$T" '
  echo -n "librknnrt : "; ldconfig -p | grep -m1 -o "librknnrt.so.*"  || echo "MISSING"
  echo -n "librkllmrt: "; ldconfig -p | grep -m1 -o "librkllmrt.so.*" || echo "MISSING"
  echo -n "llm_demo  : "; command -v llm_demo || echo "MISSING"
  echo -n "rknnlite  : "; python3 -c "import rknnlite; print(\"import OK\")" 2>/dev/null || echo "MISSING (row 17 degrades to driver-probe only)"
  echo -n "model     : "; stat -c "%s bytes  %n" ~/npu-smoke-test/qwen3_0.6b_w4a16_g64_rk3562.rkllm 2>/dev/null || echo "MISSING"
  echo -n "python    : "; python3 --version   # wheel is cp311 — needs Python 3.11 (Bookworm)
'

cat <<EOF

Deploy complete. Next, on the tablet:
    ssh $T
    ~/$RDIR/run-candidate-smoke.sh
Evidence lands in ~/validation/row-17-*.txt and row-18-*.txt (session-001
convention). Pull it back with:
    scp "$T:validation/row-1*.txt" tests/hardware/session-001/
EOF
