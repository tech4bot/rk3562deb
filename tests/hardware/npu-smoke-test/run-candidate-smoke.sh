#!/usr/bin/env bash
# run-candidate-smoke.sh — run ON THE TABLET (SD-booted candidate image).
#
# Session-001 hardware test matrix rows 17 (RKNN) and 18 (RKLLM), isolated:
# a row-17 failure never blocks row 18. Evidence is written to ~/validation/
# as row-17-*.txt / row-18-*.txt (session-001 naming convention).
#
# Expected stack (the version contract):
#   kernel driver rknpu v0.9.8  ->  librknnrt 2.3.2  /  librkllmrt 1.3.0
# Row 18 PASS requires the llm_demo banner:
#   rkllm-runtime version: 1.3.0, rknpu driver version: 0.9.8, platform: RK3562
# with NO driver-too-low warning.
#
# Usage: run-candidate-smoke.sh
# Env overrides:
#   RKLLM_PROMPT     row-18 prompt (default: capital-of-France question)
#   RKLLM_MAX_NEW    max_new_tokens   (default 256 — Qwen3 emits a <think>
#                    block first; too small and the answer gets truncated)
#   RKLLM_MAX_CTX    max_context_len  (default 512)
#   SKIP_FIXFREQ=1   skip the clock-pinning script (perf numbers then vary;
#                    note the pinning persists until reboot)
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EV="$HOME/validation"
STAMP="$(date +%Y%m%d-%H%M%S)"
mkdir -p "$EV"

RKNN_MODEL="$HERE/mobilenet_v2_rk3562.rknn"
RKLLM_MODEL="$HERE/qwen3_0.6b_w4a16_g64_rk3562.rkllm"
PROMPT="${RKLLM_PROMPT:-What is the capital of France? Answer in one short sentence.}"
MAX_NEW="${RKLLM_MAX_NEW:-256}"
MAX_CTX="${RKLLM_MAX_CTX:-512}"

R17="FAIL"; R18="FAIL"

############################################################################
echo "################ ROW 17 — RKNN runtime (librknnrt 2.3.2) ################"
############################################################################

DRV_F="$EV/row-17-driver-$STAMP.txt"
{
  echo "# session-001 row 17 driver probe — $(date -Is)"
  echo "# kernel: $(uname -r)"
  echo "--- /sys/kernel/debug/rknpu/version"
  sudo cat /sys/kernel/debug/rknpu/version 2>&1
  echo "--- devfreq node"
  if [ -e /sys/class/devfreq/ff300000.npu ]; then
    echo "devfreq: present"
  else
    echo "devfreq: MISSING (DT node disabled? see wiki 03)"
  fi
  echo "--- dmesg | rknpu (last 10)"
  sudo dmesg 2>/dev/null | grep -i rknpu | tail -10
  echo "--- librknnrt in ldconfig"
  ldconfig -p | grep librknnrt || echo "librknnrt: NOT IN LDCONFIG (install debs/librknnrt_2.3.2-1_arm64.deb)"
} | tee "$DRV_F"

DRV_OK=0
grep -q "v0.9.8" "$DRV_F" && [ -e /sys/class/devfreq/ff300000.npu ] && DRV_OK=1
LIB_OK=0
ldconfig -p | grep -q librknnrt && LIB_OK=1

if python3 -c "import rknnlite" 2>/dev/null; then
  echo "--- row 17 inference: MobileNetV2 via rknnlite (50 iterations)"
  LOAD_F="$EV/row-17-npu-load-$STAMP.txt"
  INF_F="$EV/row-17-rknn-inference-$STAMP.txt"
  { echo "# NPU load before:"; sudo cat /sys/kernel/debug/rknpu/load 2>&1; } > "$LOAD_F"
  ( sleep 3; { echo "# NPU load during:"; sudo cat /sys/kernel/debug/rknpu/load 2>&1; } >> "$LOAD_F" ) &
  SAMPLER=$!
  python3 "$HERE/npu_smoke_test.py" "$RKNN_MODEL" 50 2>&1 | tee "$INF_F"
  RC17=${PIPESTATUS[0]}
  wait "$SAMPLER" 2>/dev/null
  { echo "# NPU load after:"; sudo cat /sys/kernel/debug/rknpu/load 2>&1; } >> "$LOAD_F"
  cat "$LOAD_F"
  if [ "$RC17" -eq 0 ] && [ "$DRV_OK" -eq 1 ]; then R17="PASS"; fi
else
  echo "--- rknnlite NOT importable: row 17 degrades to driver-probe + librknnrt presence."
  echo "    (Full row 17 = inference; re-run deploy-to-candidate.sh step 4, or on-device:"
  echo "     pip3 install --break-system-packages --no-deps $HERE/rknn_toolkit_lite2-2.3.2-cp311-*.whl)"
  if [ "$DRV_OK" -eq 1 ] && [ "$LIB_OK" -eq 1 ]; then R17="PARTIAL"; fi
fi

{
  echo "row 17 (RKNN): $R17  ($(date -Is))"
  echo "criteria: driver v0.9.8 + devfreq present + librknnrt 2.3.2 loaded;"
  echo "          PASS additionally requires 50 MobileNetV2 inferences via rknnlite."
  echo "PARTIAL = driver+library verified but no executable inference (rknnlite missing)."
} | tee "$EV/row-17-result-$STAMP.txt"

############################################################################
echo ""
echo "################ ROW 18 — RKLLM (librkllmrt 1.3.0 + llm_demo) ################"
############################################################################

if ! command -v llm_demo >/dev/null; then
  echo "llm_demo missing — install debs/librkllmrt_1.3.0-2_arm64.deb" | tee "$EV/row-18-result-$STAMP.txt"
elif [ ! -f "$RKLLM_MODEL" ]; then
  echo "model missing: $RKLLM_MODEL (751 MiB, staged by deploy-to-candidate.sh — NOT /tmp, it's a 512 MiB tmpfs)" | tee "$EV/row-18-result-$STAMP.txt"
else
  if [ "${SKIP_FIXFREQ:-0}" != "1" ] && [ -x /usr/share/rkllm-demo/fix_freq_rk3562.sh ]; then
    echo "--- pinning NPU/CPU/DDR clocks for reproducible tok/s (persists until reboot)"
    sudo bash /usr/share/rkllm-demo/fix_freq_rk3562.sh 2>&1 | tee "$EV/row-18-fixfreq-$STAMP.txt"
  fi

  LLM_F="$EV/row-18-llm-demo-$STAMP.txt"
  echo "--- llm_demo: model=$(basename "$RKLLM_MODEL") max_new_tokens=$MAX_NEW max_context_len=$MAX_CTX"
  echo "--- prompt: $PROMPT"
  {
    echo "# session-001 row 18 — $(date -Is)"
    echo "# cmd: RKLLM_LOG_LEVEL=1 llm_demo $(basename "$RKLLM_MODEL") $MAX_NEW $MAX_CTX"
    echo "# prompt: $PROMPT"
  } > "$LLM_F"
  T0=$(date +%s)
  # llm_demo is interactive (reads 'user:' lines from stdin; 'exit' quits) —
  # feed the fixed prompt then exit. RKLLM_LOG_LEVEL=1 makes librkllmrt print
  # the Prefill/Generate perf table (tokens per second) after generation.
  printf '%s\nexit\n' "$PROMPT" | RKLLM_LOG_LEVEL=1 timeout 900 llm_demo "$RKLLM_MODEL" "$MAX_NEW" "$MAX_CTX" 2>&1 | tee -a "$LLM_F"
  RC18=${PIPESTATUS[1]}
  T1=$(date +%s)
  [ "$RC18" -eq 124 ] && echo "TIMEOUT: llm_demo exceeded 900 s" | tee -a "$LLM_F"

  # -- perf extraction (first tok/s datapoint for this stack) --
  PERF_F="$EV/row-18-perf-$STAMP.txt"
  {
    echo "# row 18 perf — wall clock (init+load+prefill+generate+teardown): $((T1 - T0)) s"
    if grep -Eq 'Tokens per Second|Prefill|Generate' "$LLM_F"; then
      grep -E 'Stage|Total Time|Prefill|Generate|Tokens per Second|-{10,}' "$LLM_F"
    else
      echo "no RKLLM perf table found in output — RKLLM_LOG_LEVEL=1 was set;"
      echo "check $LLM_F for the runtime's actual log wording."
    fi
  } | tee "$PERF_F"

  # -- pass/fail --
  BANNER_OK=0; grep -q "rkllm-runtime version: 1.3.0, rknpu driver version: 0.9.8, platform: RK3562" "$LLM_F" && BANNER_OK=1
  INIT_OK=0;   grep -q "rkllm init success" "$LLM_F" && INIT_OK=1
  # Generated text = everything from "robot:" on, with the interactive
  # "user: "/"robot: " prefixes stripped (llm_demo prints them without
  # newlines, so a short answer shares a line with them) and runtime log
  # lines ("I rkllm: ...") dropped.
  ANSWER_OK=0
  sed -n '/robot:/,$p' "$LLM_F" | sed 's/^user: *//; s/^robot: *//' \
    | grep -v '^I rkllm' | grep -q '[[:alnum:]]' && ANSWER_OK=1
  WARN_LINES="$(grep -iE 'driver.*(low|old|mismatch|not match)|please update' "$LLM_F" || true)"

  if [ "$RC18" -eq 0 ] && [ "$BANNER_OK" -eq 1 ] && [ "$INIT_OK" -eq 1 ] && [ "$ANSWER_OK" -eq 1 ] && [ -z "$WARN_LINES" ]; then
    R18="PASS"
  fi
  {
    echo "row 18 (RKLLM): $R18  ($(date -Is))"
    echo "  exit code            : $RC18"
    echo "  version banner exact : $([ $BANNER_OK -eq 1 ] && echo yes || echo 'NO — check runtime/driver versions in output')"
    echo "  rkllm init success   : $([ $INIT_OK -eq 1 ] && echo yes || echo NO)"
    echo "  non-empty answer     : $([ $ANSWER_OK -eq 1 ] && echo yes || echo NO)"
    echo "  driver-low warnings  : ${WARN_LINES:-none}"
    echo "  correctness (soft)   : $(grep -qi 'paris' "$LLM_F" && echo "answer mentions Paris" || echo "answer does NOT mention Paris — read $LLM_F (soft check only, not a FAIL criterion)")"
  } | tee "$EV/row-18-result-$STAMP.txt"
fi

############################################################################
echo ""
echo "=========================== SUMMARY (session-001) ==========================="
echo "row 17 (RKNN)  : $R17"
echo "row 18 (RKLLM) : $R18"
echo "evidence       : $EV/row-17-*-$STAMP.txt  $EV/row-18-*-$STAMP.txt"
echo "pull to Conrad : scp '$(whoami)@<this-ip>:validation/row-1*.txt' tests/hardware/session-001/"
[ "$R17" = "PASS" ] && [ "$R18" = "PASS" ]
