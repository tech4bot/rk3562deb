#!/bin/bash
# Pin DDR frequency on RK3562 (performance mode at 920 MHz).
#
# Without this, the dmc_ondemand governor scales DRAM between 528 MHz and 920 MHz.
# Frequency transitions while VOP2 is scanning out cause bus/page faults and memory corruption.
LOG=/var/log/c20e-dvfs-policy.log
exec >>"$LOG" 2>&1
echo "=== c20e dvfs policy $(date -Is) ==="

for d in /sys/class/devfreq/*dmc* /sys/class/devfreq/dmc; do
    [ -d "$d" ] || continue
    echo "device: $d"
    echo "  before: $(cat "$d/governor" 2>/dev/null) @ $(cat "$d/cur_freq" 2>/dev/null)"
    if echo performance > "$d/governor" 2>/dev/null; then
        echo "  after:  $(cat "$d/governor" 2>/dev/null) @ $(cat "$d/cur_freq" 2>/dev/null)"
    else
        echo "  FAILED to set governor"
    fi
done
exit 0
