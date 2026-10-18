#!/bin/bash
# C20e playback bench: play a local clip in its own Chrome instance and report
# the frame statistics the <video> element itself reports, plus CPU spent by
# Chrome and whether the hardware decoder was open.
#   usage: run.sh <label> <clip> <seconds> [extra chrome args...]
set -u
LABEL="$1"; CLIP="$2"; SECS="$3"; shift 3
export XDG_RUNTIME_DIR="/run/user/$(id -u)" WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"
cd "$(dirname "$(readlink -f "$0")")" || exit 1
pkill -f 'python3 bench.py' 2>/dev/null; sleep 0.3
: > bench.log
python3 bench.py 8099 & SRV=$!
trap 'kill $SRV 2>/dev/null' EXIT
sleep 1

rm -rf /tmp/chr-bench-$LABEL
RK_VAAPI_LOG=stderr google-chrome-stable --user-data-dir=/tmp/chr-bench-$LABEL \
  --ozone-platform=wayland --no-first-run --no-default-browser-check \
  --autoplay-policy=no-user-gesture-required --start-maximized "$@" \
  "http://127.0.0.1:8099/index.html?f=$CLIP" > /tmp/chr-$LABEL.log 2>&1 &
CHROME=$!
sleep 6   # startup + first frames

jiff(){ awk '{print $14+$15}' /proc/$1/stat 2>/dev/null || echo 0; }
pids(){ pgrep -f "chr-bench-$LABEL" ; }
declare -A T0
for p in $(pids); do T0[$p]=$(jiff $p); done
S0=$(date +%s.%N)
MPP=0
for i in $(seq 1 "$SECS"); do
  sleep 1
  ls -l /proc/*/fd 2>/dev/null >/dev/null
  for p in $(pids); do
    if ls -l /proc/$p/fd 2>/dev/null | grep -q mpp_service; then MPP=$((MPP+1)); break; fi
  done
done
S1=$(date +%s.%N)
TOT=0
for p in $(pids); do t=$(jiff $p); TOT=$((TOT + t - ${T0[$p]:-$t})); done
WALL=$(echo "$S1 - $S0" | bc)
HZ=$(getconf CLK_TCK)

echo "=== $LABEL  clip=$CLIP  window=${WALL}s  chrome flags: $*"
echo "--- chrome CPU: $(echo "scale=1; $TOT * 100 / $HZ / $WALL" | bc)% of one core (all chrome processes)"
echo "--- hardware decoder open in $MPP of $SECS samples"
echo "--- video element stats (last 8 s):"; tail -8 bench.log
D=$(awk -F'dropped=' 'END{print $2+0}' bench.log); TT=$(awk -F'total=' '{d=$2+0} END{print d}' bench.log)
echo "--- totals: frames=$TT dropped=$D"
echo "--- driver log lines: $(grep -c . /tmp/chr-$LABEL.log)"
grep -iE 'error|fail|not ready|placeholder|unsupported' /tmp/chr-$LABEL.log | sort | uniq -c | sort -rn | head -8
pkill -f "chr-bench-$LABEL" 2>/dev/null
