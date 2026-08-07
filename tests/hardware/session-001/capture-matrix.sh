#!/usr/bin/env bash
# capture-matrix.sh — runs ON the booted candidate (samwise), as user frodo.
#
# Captures evidence for all 20 rows of docs/HARDWARE_TEST_MATRIX.md into a
# timestamped directory under ~/validation/ (never /tmp — that's a 512 MiB
# tmpfs on this image and must not be filled by evidence capture).
#
# Design: every row is isolated. A failure or missing sysfs node in one row
# must never abort the rest of the capture. Each row function writes its own
# raw command output PLUS a final "VERDICT: <PASS|FAIL|MANUAL|SKIP> - reason"
# line. The driver loop extracts that line into summary.txt.
#
# Deliberately NOT using `set -e`: many rows probe optional sysfs nodes that
# legitimately don't exist (e.g. a missing devfreq node is itself evidence,
# not a script bug). `set -u` and `pipefail` are safe and kept.
set -uo pipefail

SESSION="session-001"
DATE_TAG="$(date +%Y%m%d-%H%M%S)"
EVID="${HOME}/validation/${SESSION}-${DATE_TAG}"
mkdir -p "$EVID"

echo "=== Samwise hardware validation: ${SESSION} ==="
echo "Host:        $(hostname 2>/dev/null || echo unknown)"
echo "Date:        $(date -Iseconds)"
echo "Evidence -> ${EVID}"
echo ""

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

safe_cat() {
    # Print a file's contents, or a clear MISSING marker if unreadable.
    local f="$1"
    if [[ -r "$f" ]]; then
        cat "$f" 2>&1
    else
        echo "MISSING or unreadable: $f"
    fi
}

safe_run() {
    # Run a command, never let its failure propagate to the caller.
    "$@" 2>&1
    return 0
}

glob_first() {
    # Expand a glob pattern (passed as literal text, e.g. '/sys/class/backlight/*')
    # and print the first existing match, or nothing.
    local pattern="$1" f
    for f in $pattern; do
        if [[ -e "$f" ]]; then
            printf '%s\n' "$f"
            return 0
        fi
        break
    done
}

# ---------------------------------------------------------------------------
# Row functions — one per matrix row. Each prints raw evidence to stdout,
# ending with a single "VERDICT: ..." line. Caller redirects stdout+stderr
# to the row's evidence file.
# ---------------------------------------------------------------------------

row01_boot() {
    echo "# Row 1 — Cold boot from candidate microSD"
    echo "# This script is executing on-device over SSH, which is only possible if"
    echo "# the system reached a network-reachable login state. That is strong"
    echo "# automatic evidence for this row, but the pass condition explicitly"
    echo "# requires 'without manual recovery' (i.e. no serial-console rescue was"
    echo "# needed to get here) — that part can only be attested by whoever"
    echo "# watched the physical boot."
    echo ""
    echo "-- uptime --"
    safe_run uptime
    echo ""
    echo "-- boot time (uptime -s) --"
    safe_run uptime -s
    echo ""
    echo "-- kernel cmdline --"
    safe_cat /proc/cmdline
    echo ""
    echo "-- systemd-analyze (boot timing, if available) --"
    if command -v systemd-analyze >/dev/null 2>&1; then
        safe_run systemd-analyze
    else
        echo "systemd-analyze not available"
    fi
    echo ""
    echo "-- failed systemd units --"
    safe_run systemctl --failed --no-legend
    echo ""
    echo "VERDICT: MANUAL - SSH reachability (this script running) is strong evidence of a successful boot; confirm no serial-console recovery was required during the physical power-on before marking this row PASS."
}

row02_root() {
    echo "# Row 2 — Root filesystem identity (must be candidate microSD, never eMMC)"
    echo "-- findmnt / --"
    safe_run findmnt /
    echo ""
    echo "-- lsblk --"
    safe_run lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,MODEL
    echo ""
    local src
    src="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
    echo "root source (findmnt -n -o SOURCE /): ${src:-<empty>}"
    echo ""
    if [[ -z "$src" ]]; then
        echo "VERDICT: FAIL - could not determine root filesystem source via findmnt."
    elif [[ "$src" == *mmcblk2* ]]; then
        echo "VERDICT: FAIL - root source '$src' matches mmcblk2, the tablet eMMC. This must never happen; investigate immediately, do not proceed with further testing on this boot."
    elif [[ "$src" == *mmcblk0* ]]; then
        echo "VERDICT: PASS - root source '$src' is mmcblk0, the SD-card controller per docs/BOOT_CHAIN_DISCOVERY.md (mmc@ff880000 = SD, mmc@ff870000 = eMMC/mmcblk2)."
    else
        echo "VERDICT: MANUAL - root source '$src' matches neither the expected SD pattern (mmcblk0) nor the forbidden eMMC pattern (mmcblk2). Confirm by hand which physical device this is before trusting this row."
    fi
}

row03_ssh() {
    echo "# Row 3 — Network login (SSH)"
    echo "# This capture script itself only runs after run-remote.sh established an"
    echo "# SSH session, so SSH access is already demonstrated by execution."
    echo ""
    echo "-- current session --"
    safe_run who
    echo ""
    echo "-- sshd status --"
    safe_run systemctl is-active ssh
    safe_run systemctl is-active sshd
    echo ""
    echo "-- listening SSH socket --"
    safe_run ss -tlnp 'sport = :22'
    echo ""
    echo "VERDICT: PASS - this evidence file only exists because an SSH session ran the capture script successfully."
}

row04_wifi() {
    echo "# Row 4 — Wi-Fi: join expected LAN"
    local wdev
    wdev="$(iw dev 2>/dev/null | awk '/Interface/{print $2; exit}')"
    echo "-- iw dev --"
    safe_run iw dev
    echo ""
    if [[ -z "$wdev" ]]; then
        echo "VERDICT: FAIL - no wireless interface found via 'iw dev'."
        return
    fi
    echo "wireless interface detected: $wdev"
    echo ""
    echo "-- iw dev $wdev link --"
    local link_out
    link_out="$(iw dev "$wdev" link 2>&1)"
    echo "$link_out"
    echo ""
    echo "-- ip -4 addr show $wdev --"
    safe_run ip -4 addr show "$wdev"
    echo ""
    local has_ip
    has_ip="$(ip -4 -o addr show "$wdev" 2>/dev/null | awk '{print $4}' | head -1)"
    if [[ "$link_out" == *"Connected to"* && -n "$has_ip" ]]; then
        echo "VERDICT: PASS - $wdev associated and has IPv4 address $has_ip."
    elif [[ "$link_out" == *"Not connected"* ]]; then
        echo "VERDICT: FAIL - $wdev reports 'Not connected'."
    else
        echo "VERDICT: MANUAL - could not cleanly determine association/IP state for $wdev; review output above."
    fi
}

row05_display() {
    echo "# Row 5 — Display: DSI panel"
    echo "# Panel content itself must be eyeballed by the operator; this only"
    echo "# captures the kernel-side state (connector status, mode, resolution)."
    echo ""
    echo "-- DRM connector status --"
    for f in /sys/class/drm/card*/status; do
        [[ -e "$f" ]] || continue
        echo "$f: $(safe_cat "$f")"
    done
    echo ""
    echo "-- DRM connector modes (first entries) --"
    for f in /sys/class/drm/card*-DSI-*/modes /sys/class/drm/card*/modes; do
        [[ -e "$f" ]] || continue
        echo "$f:"
        safe_cat "$f" | head -5
    done
    echo ""
    echo "-- framebuffer geometry (if present) --"
    for f in /sys/class/graphics/fb*/virtual_size /sys/class/graphics/fb*/modes; do
        [[ -e "$f" ]] || continue
        echo "$f: $(safe_cat "$f")"
    done
    echo ""
    echo "VERDICT: MANUAL - visually confirm: panel shows content, resolution is 800x1280, orientation is correct/usable (rotate=90 for landscape per docs/wiki/01-hardware-baseline.md), and the image is stable (no flicker/tearing) for at least a minute."
}

row06_backlight() {
    echo "# Row 6 — Backlight brightness control"
    local bl
    bl="$(glob_first '/sys/class/backlight/*')"
    if [[ -z "$bl" ]]; then
        echo "VERDICT: FAIL - no /sys/class/backlight/* device found."
        return
    fi
    echo "backlight device: $bl"
    echo ""
    echo "-- max_brightness --"
    local maxb
    maxb="$(safe_cat "$bl/max_brightness")"
    echo "$maxb"
    echo ""
    echo "-- current brightness (before) --"
    local before
    before="$(safe_cat "$bl/brightness")"
    echo "$before"
    echo ""
    if ! [[ "$maxb" =~ ^[0-9]+$ ]] || ! [[ "$before" =~ ^[0-9]+$ ]]; then
        echo "VERDICT: MANUAL - could not parse numeric brightness values; inspect $bl manually."
        return
    fi
    # Gentle bounded test write: nudge to ~70% of max, verify, then restore.
    local testval=$(( maxb * 70 / 100 ))
    (( testval < 1 )) && testval=1
    echo "-- writing test brightness $testval (sudo) --"
    if echo "$testval" | sudo tee "$bl/brightness" >/dev/null 2>&1; then
        sleep 1
        local after
        after="$(safe_cat "$bl/brightness")"
        echo "brightness after write: $after"
        echo "-- restoring original brightness $before --"
        echo "$before" | sudo tee "$bl/brightness" >/dev/null 2>&1 || echo "WARNING: failed to restore original brightness $before"
        if [[ "$after" == "$testval" ]]; then
            echo "VERDICT: PASS - wrote $testval, read back $after, restored to $before. Confirm visually the screen dimmed/brightened during the test window."
        else
            echo "VERDICT: FAIL - wrote $testval but read back '$after'."
        fi
    else
        echo "VERDICT: FAIL - write to $bl/brightness failed (sudo tee returned non-zero)."
    fi
}

row07_touch() {
    echo "# Row 7 — Touch (GSL3673)"
    echo "-- candidate touch device from /proc/bus/input/devices --"
    local evnum
    evnum="$(awk '
        /^N: Name=/ { name=$0 }
        /^H: Handlers=/ {
            if (tolower(name) ~ /gsl|touch/) {
                for (i=1;i<=NF;i++) if ($i ~ /^event[0-9]+/) { print $i; exit }
            }
        }
    ' /proc/bus/input/devices)"
    safe_cat /proc/bus/input/devices | grep -iB4 -A1 'gsl\|touch' || echo "no name containing 'gsl' or 'touch' found in /proc/bus/input/devices"
    echo ""
    if [[ -z "$evnum" ]]; then
        echo "VERDICT: MANUAL - could not auto-identify a touch input device node. Run 'evtest' by hand, pick the GSL3673/touchscreen entry, and touch the panel to confirm events."
        return
    fi
    local devnode="/dev/input/$evnum"
    echo "candidate device node: $devnode"
    echo ""
    if [[ ! -r "$devnode" ]]; then
        echo "VERDICT: MANUAL - $devnode not readable by this user; re-run with sudo or 'evtest $devnode' interactively."
        return
    fi
    if ! command -v evtest >/dev/null 2>&1; then
        echo "VERDICT: MANUAL - evtest not installed. Install it (apt install evtest) and run 'evtest $devnode' while touching the panel."
        return
    fi
    echo "-- attempting an 8-second non-interactive capture; TOUCH THE SCREEN NOW if running this live --"
    local out
    out="$(timeout 8 evtest "$devnode" 2>&1 || true)"
    echo "$out" | tail -40
    echo ""
    if echo "$out" | grep -q "Event: time"; then
        echo "VERDICT: PASS - touch events observed on $devnode during the capture window."
    else
        echo "VERDICT: MANUAL - no events captured in the automated 8s window (this is expected if nobody touched the screen during capture). Re-run interactively: evtest $devnode"
    fi
}

row08_power() {
    echo "# Row 8 — Battery and charging"
    local any=0
    for d in /sys/class/power_supply/*/; do
        [[ -d "$d" ]] || continue
        any=1
        echo "-- $d --"
        echo "type:     $(safe_cat "${d}type")"
        echo "status:   $(safe_cat "${d}status")"
        echo "capacity: $(safe_cat "${d}capacity")"
        echo ""
    done
    if (( any == 0 )); then
        echo "VERDICT: FAIL - no /sys/class/power_supply/* nodes found."
        return
    fi
    local cap status_val
    cap="$(safe_cat /sys/class/power_supply/*battery*/capacity 2>/dev/null | head -1)"
    status_val="$(safe_cat /sys/class/power_supply/*battery*/status 2>/dev/null | head -1)"
    if [[ "$cap" =~ ^[0-9]+$ ]] && (( cap >= 0 && cap <= 100 )) && [[ -n "$status_val" && "$status_val" != MISSING* ]]; then
        echo "VERDICT: PASS - battery capacity=$cap%% status='$status_val' (plausible values)."
    else
        echo "VERDICT: MANUAL - power_supply nodes present but capacity/status could not be confidently parsed (cap='$cap' status='$status_val'); review above."
    fi
}

row09_suspend() {
    echo "# Row 9 — No-suspend policy"
    echo "# Full confirmation requires letting the system idle for the observation"
    echo "# window and checking it never suspended; that part is MANUAL. This row"
    echo "# captures the policy/config snapshot automatically."
    echo ""
    echo "-- /sys/power/state (available states) --"
    safe_cat /sys/power/state
    echo ""
    echo "-- systemd sleep targets --"
    for t in sleep.target suspend.target hibernate.target hybrid-sleep.target; do
        echo "$t: $(systemctl is-enabled "$t" 2>&1) / $(systemctl is-active "$t" 2>&1)"
    done
    echo ""
    echo "-- logind suspend handling --"
    safe_run grep -E '^(Handle|IdleAction)' /etc/systemd/logind.conf
    echo ""
    echo "-- dmesg suspend/resume markers so far this boot --"
    safe_run bash -c "dmesg | grep -iE 'PM: suspend|PM: resume|freeze' | tail -20"
    echo ""
    echo "VERDICT: MANUAL - review policy snapshot above, then leave the device idle (screen on, no input) for the agreed observation window and re-check 'uptime' plus dmesg for suspend/resume markers before marking PASS."
}

row10_iio() {
    echo "# Row 10 — IIO accelerometer (DA223 / Mir3DA / SC7A20)"
    local any=0
    for d in /sys/bus/iio/devices/iio:device*/; do
        [[ -d "$d" ]] || continue
        any=1
        echo "-- $d --"
        echo "name: $(safe_cat "${d}name")"
        for axis in in_accel_x_raw in_accel_y_raw in_accel_z_raw; do
            [[ -e "${d}${axis}" ]] && echo "$axis: $(safe_cat "${d}${axis}")"
        done
        echo ""
    done
    if (( any == 0 )); then
        echo "VERDICT: FAIL - no /sys/bus/iio/devices/iio:device* nodes found."
        return
    fi
    local names
    names="$(cat /sys/bus/iio/devices/iio:device*/name 2>/dev/null)"
    if echo "$names" | grep -qiE 'da223|mir3da|sc7a20'; then
        echo "VERDICT: PASS - matched expected accelerometer name (da223/mir3da/sc7a20) among: $names"
    else
        echo "VERDICT: MANUAL - IIO device(s) present but name(s) '$names' don't match the expected da223/mir3da/sc7a20 set; confirm this is the correct sensor."
    fi
}

row11_thermal() {
    echo "# Row 11 — Thermal zones"
    local any=0 all_ok=1
    for z in /sys/class/thermal/thermal_zone*/; do
        [[ -d "$z" ]] || continue
        any=1
        local type temp
        type="$(safe_cat "${z}type")"
        temp="$(safe_cat "${z}temp")"
        echo "$z type=$type temp=$temp"
        if ! [[ "$temp" =~ ^-?[0-9]+$ ]]; then
            all_ok=0
        elif (( temp < -10000 || temp > 100000 )); then
            all_ok=0
        fi
    done
    echo ""
    if (( any == 0 )); then
        echo "VERDICT: FAIL - no /sys/class/thermal/thermal_zone* nodes found."
    elif (( all_ok == 1 )); then
        echo "VERDICT: PASS - all thermal zones report plausible millidegree readings (-10C..100C range)."
    else
        echo "VERDICT: MANUAL - at least one thermal zone reported an unparseable or implausible value; review above."
    fi
}

row12_input() {
    echo "# Row 12 — Input devices (power key, ADC/volume keys, headset)"
    safe_cat /proc/bus/input/devices
    echo ""
    local devices
    devices="$(safe_cat /proc/bus/input/devices)"
    local have_power=0 have_vol=0 have_headset=0
    echo "$devices" | grep -iq 'power' && have_power=1
    echo "$devices" | grep -iqE 'vol|adc.?keys|adc_keys' && have_vol=1
    echo "$devices" | grep -iqE 'headset|headphone|jack' && have_headset=1
    echo "power-key-like entry found: $have_power"
    echo "volume/adc-key-like entry found: $have_vol"
    echo "headset/jack-like entry found: $have_headset"
    echo ""
    if (( have_power == 1 && have_vol == 1 )); then
        echo "VERDICT: PASS - power key and volume/ADC key entries both found (headset present: $have_headset)."
    elif (( have_power == 1 )); then
        echo "VERDICT: MANUAL - power key found but volume/ADC key entry not confidently matched; confirm by name in the listing above."
    else
        echo "VERDICT: MANUAL - could not confidently match expected input device names; review /proc/bus/input/devices above by hand."
    fi
}

row13_audio() {
    echo "# Row 13 — ALSA audio devices"
    if ! command -v aplay >/dev/null 2>&1; then
        echo "VERDICT: FAIL - aplay not installed (alsa-utils missing)."
        return
    fi
    echo "-- aplay -l --"
    local out
    out="$(aplay -l 2>&1)"
    echo "$out"
    echo ""
    echo "-- aplay -L (PCM names) --"
    safe_run aplay -L
    echo ""
    if echo "$out" | grep -q "^card "; then
        echo "VERDICT: PASS - at least one ALSA card enumerated. Actual audible playback is MANUAL: aplay -D plughw:0,0 /usr/share/sounds/alsa/Front_Center.wav (or similar) and confirm sound is heard."
    else
        echo "VERDICT: FAIL - aplay -l listed no cards."
    fi
}

row14_storage() {
    echo "# Row 14 — microSD I/O"
    echo "# NOTE: the matrix's literal command targets /tmp, which on this image is"
    echo "# a 512 MiB tmpfs (RAM), so it does NOT exercise the SD block device at"
    echo "# all. We run it anyway for literal compliance (bounded to 10 MiB, safe"
    echo "# for the tmpfs), and additionally run an equivalent write against the"
    echo "# real rootfs (the evidence directory itself, which lives on the SD-boot"
    echo "# root partition) to actually validate storage I/O. See session-001"
    echo "# README for this discrepancy."
    echo ""
    echo "-- tmpfs test: dd if=/dev/zero of=/tmp/session001-test bs=1M count=10 --"
    safe_run dd if=/dev/zero of=/tmp/session001-test bs=1M count=10 conv=fsync status=progress
    rm -f /tmp/session001-test
    echo ""
    echo "-- SD-rootfs test: dd if=/dev/zero of=\$EVID/row14-sd-test.bin bs=1M count=10 --"
    local sdtest="${EVID}/row14-sd-test.bin"
    local rc=0
    dd if=/dev/zero of="$sdtest" bs=1M count=10 conv=fsync status=progress 2>&1 || rc=$?
    sync
    ls -la "$sdtest" 2>&1
    rm -f "$sdtest"
    echo ""
    echo "-- df -h of root --"
    safe_run df -h /
    echo ""
    echo "-- recent dmesg I/O errors (mmc/ext4) --"
    local dmesg_errs
    dmesg_errs="$(dmesg 2>&1 | grep -iE 'mmc.*error|ext4.*error|i/o error' || true)"
    echo "${dmesg_errs:-<none>}"
    echo ""
    if (( rc == 0 )) && [[ -z "$dmesg_errs" ]]; then
        echo "VERDICT: PASS - both tmpfs and SD-rootfs writes completed cleanly, no mmc/ext4 I/O errors in dmesg."
    else
        echo "VERDICT: FAIL - SD-rootfs dd rc=$rc or dmesg shows storage errors; review above."
    fi
}

row15_gpu() {
    echo "# Row 15 — GPU/DRM render device"
    echo "-- ls -la /dev/dri/ --"
    local out
    out="$(ls -la /dev/dri/ 2>&1)"
    echo "$out"
    echo ""
    if echo "$out" | grep -q 'card0' && echo "$out" | grep -q 'renderD'; then
        echo "VERDICT: PASS - both a card node and a renderD* node are present under /dev/dri/."
    elif echo "$out" | grep -q 'card0'; then
        echo "VERDICT: MANUAL - card0 present but no renderD* node found; confirm Mali GPU driver/libmali package is installed."
    else
        echo "VERDICT: FAIL - no /dev/dri/card0 found."
    fi
}

row16_media() {
    echo "# Row 16 — Media/RGA device nodes"
    local mpp_ok=0 rga_ok=0
    if [[ -e /dev/mpp_service ]]; then
        mpp_ok=1
        ls -la /dev/mpp_service
    else
        echo "MISSING: /dev/mpp_service"
    fi
    if [[ -e /dev/rga ]]; then
        rga_ok=1
        ls -la /dev/rga
    else
        echo "MISSING: /dev/rga"
    fi
    echo ""
    if (( mpp_ok == 1 && rga_ok == 1 )); then
        echo "VERDICT: PASS - both /dev/mpp_service and /dev/rga present. Running an actual media/RGA test utility is MANUAL/out of scope for this capture."
    else
        echo "VERDICT: FAIL - missing mpp_service (present=$mpp_ok) and/or rga (present=$rga_ok) device node(s)."
    fi
}

row17_npu_rknn() {
    echo "# Row 17 — NPU (RKNN) — driver/plumbing probe only"
    echo "# Actual inference execution (the real PASS/FAIL for this row) is owned"
    echo "# by tests/hardware/npu-smoke-test/run-smoke-test.sh — run that kit"
    echo "# separately and cite its evidence/<timestamp>/ dir for this row."
    echo ""
    echo "-- driver version --"
    local ver
    ver="$(sudo cat /sys/kernel/debug/rknpu/version 2>&1)"
    echo "$ver"
    echo ""
    echo "-- devfreq node --"
    if [[ -d /sys/class/devfreq/ff300000.npu ]]; then
        echo "present: /sys/class/devfreq/ff300000.npu"
        safe_cat /sys/class/devfreq/ff300000.npu/governor
        safe_cat /sys/class/devfreq/ff300000.npu/cur_freq
    else
        echo "MISSING: /sys/class/devfreq/ff300000.npu"
    fi
    echo ""
    echo "-- dmesg rknpu probe --"
    safe_run bash -c "dmesg | grep -i rknpu"
    echo ""
    echo "-- NPU load, read once here (idle baseline) --"
    echo "# The before/during-inference comparison that answers wiki 06 open"
    echo "# question #1 is captured by the npu-smoke-test kit itself; do not"
    echo "# duplicate that here."
    safe_run sudo cat /sys/kernel/debug/rknpu/load
    echo ""
    if echo "$ver" | grep -q "v0.9.8" && [[ -d /sys/class/devfreq/ff300000.npu ]]; then
        echo "VERDICT: MANUAL - driver v0.9.8 present and devfreq node bound (probe-level PASS); run tests/hardware/npu-smoke-test/run-smoke-test.sh for the actual inference PASS/FAIL that closes this row."
    else
        echo "VERDICT: FAIL - driver version or devfreq node did not match expectations at the probe level; see above. (This alone fails row 17 regardless of the smoke-test kit's result.)"
    fi
}

row18_rkllm() {
    echo "# Row 18 — RKLLM — runtime presence probe only"
    echo "# Actual small-model demo execution (the real PASS/FAIL for this row) is"
    echo "# owned by tests/hardware/npu-smoke-test/ — run that kit separately."
    echo ""
    echo "-- librkllmrt presence --"
    local libpath
    libpath="$(find /usr/lib /usr/lib64 /usr/local/lib /oem -name 'librkllmrt.so*' 2>/dev/null | head -1)"
    if [[ -n "$libpath" ]]; then
        echo "found: $libpath"
        ls -la "$libpath"
    else
        echo "MISSING: librkllmrt.so* not found under /usr/lib, /usr/lib64, /usr/local/lib, /oem"
        echo "expected package: debs/librkllmrt_1.3.0-2_arm64.deb (see docs/wiki/01-hardware-baseline.md)"
    fi
    echo ""
    if [[ -n "$libpath" ]]; then
        echo "VERDICT: MANUAL - librkllmrt runtime present at probe level; run the npu-smoke-test kit's RKLLM demo for the actual PASS/FAIL that closes this row."
    else
        echo "VERDICT: FAIL - librkllmrt runtime not found on-device; install debs/librkllmrt_1.3.0-2_arm64.deb before attempting the RKLLM demo."
    fi
}

row19_dashboard() {
    echo "# Row 19 — Dashboard: hardware monitor collectors"
    echo "# Per docs/wiki/06-future-options.md, the rk-tui dashboard and its"
    echo "# hardware collectors are FUTURE WORK, not yet wired into any image."
    echo "# There is nothing to check on this candidate."
    echo ""
    echo "-- searching for any dashboard/collector process or unit anyway --"
    safe_run bash -c "systemctl list-units --all 2>&1 | grep -i dashboard"
    safe_run bash -c "pgrep -fa 'rk-tui|dashboard' "
    echo ""
    echo "VERDICT: SKIP - no dashboard collectors exist yet on this build (rk-tui is future work per wiki 06-future-options.md); nothing to test."
}

row20_logs() {
    echo "# Row 20 — dmesg error scan"
    local errs
    errs="$(dmesg 2>&1 | grep -iE 'error|fail|timeout' || true)"
    echo "-- dmesg | grep -iE 'error|fail|timeout' --"
    echo "${errs:-<no matches>}"
    echo ""
    if [[ -z "$errs" ]]; then
        echo "VERDICT: PASS - no error/fail/timeout lines in dmesg."
        return
    fi
    local line_count
    line_count=$(echo "$errs" | wc -l)
    echo "total matching lines: $line_count"
    echo ""
    # Heuristic: collapse each line by stripping leading timestamp/pid-ish
    # numbers, then look for any message repeated 3+ times — a strong signal
    # of a recurring driver bind failure rather than a benign one-off.
    local repeats
    repeats="$(echo "$errs" | sed -E 's/^\[[^]]*\]//; s/[0-9]+/N/g' | sort | uniq -c | sort -rn | awk '$1 >= 3')"
    if [[ -n "$repeats" ]]; then
        echo "-- repeated (>=3x) normalized error signatures --"
        echo "$repeats"
        echo ""
        echo "VERDICT: FAIL - one or more error messages repeat 3+ times, consistent with a recurring driver bind failure. Investigate the lines above."
    else
        echo "VERDICT: MANUAL - $line_count error/fail/timeout line(s) present but none repeat; likely benign one-off warnings (common on any Linux boot). Human review of dmesg-errors above required before final sign-off."
    fi
}

# ---------------------------------------------------------------------------
# Driver
# ---------------------------------------------------------------------------

SUMMARY="$EVID/summary.txt"
{
    echo "Samwise hardware validation — ${SESSION}"
    echo "Captured: $(date -Iseconds)"
    echo "Host:     $(hostname 2>/dev/null || echo unknown)"
    echo "Kernel:   $(uname -r 2>/dev/null || echo unknown)"
    echo ""
    echo "Row  Area              Verdict  Evidence file"
    echo "---  ----              -------  -------------"
} > "$SUMMARY"

declare -A ROW_SLUG=(
    [1]=boot [2]=root-findmnt [3]=ssh [4]=wifi [5]=display [6]=backlight
    [7]=touch [8]=power [9]=suspend [10]=iio-sensor [11]=thermal [12]=input
    [13]=audio [14]=storage [15]=gpu-drm [16]=media-rga [17]=npu-rknn
    [18]=rkllm [19]=dashboard [20]=logs
)
declare -A ROW_AREA=(
    [1]="Boot" [2]="Root" [3]="SSH" [4]="Wi-Fi" [5]="Display" [6]="Backlight"
    [7]="Touch" [8]="Power" [9]="Suspend" [10]="IIO Sensor" [11]="Thermal"
    [12]="Input" [13]="Audio" [14]="Storage" [15]="GPU/DRM" [16]="Media/RGA"
    [17]="NPU" [18]="RKLLM" [19]="Dashboard" [20]="Logs"
)

run_row() {
    local num="$1" func="$2"
    local slug="${ROW_SLUG[$num]}"
    local area="${ROW_AREA[$num]}"
    local padded
    padded="$(printf '%02d' "$num")"
    local outfile="$EVID/row-${padded}-${slug}.txt"

    printf '[row %2d] %-16s -> %s\n' "$num" "$area" "$(basename "$outfile")"

    local rc=0
    "$func" > "$outfile" 2>&1
    rc=$?

    local verdict
    verdict="$(grep '^VERDICT:' "$outfile" | tail -1 | sed -E 's/^VERDICT:\s*([A-Z]+).*/\1/')"
    if [[ -z "$verdict" ]]; then
        verdict="FAIL"
        {
            echo ""
            echo "VERDICT: FAIL - row function exited rc=$rc without emitting a VERDICT line (script/probe error)."
        } >> "$outfile"
    fi

    printf '%2d   %-17s %-8s %s\n' "$num" "$area" "$verdict" "$(basename "$outfile")" >> "$SUMMARY"
}

# Each call isolated: a crash inside a row function only affects that row,
# because run_row invokes it in a subshell context via the `>` redirection
# and we never `set -e` at top level.
run_row 1  row01_boot
run_row 2  row02_root
run_row 3  row03_ssh
run_row 4  row04_wifi
run_row 5  row05_display
run_row 6  row06_backlight
run_row 7  row07_touch
run_row 8  row08_power
run_row 9  row09_suspend
run_row 10 row10_iio
run_row 11 row11_thermal
run_row 12 row12_input
run_row 13 row13_audio
run_row 14 row14_storage
run_row 15 row15_gpu
run_row 16 row16_media
run_row 17 row17_npu_rknn
run_row 18 row18_rkllm
run_row 19 row19_dashboard
run_row 20 row20_logs

{
    echo ""
    echo "Legend: PASS/FAIL are machine-graded where possible. MANUAL rows have"
    echo "strong automatic evidence attached but need a human observation or"
    echo "judgment call to close out (see each row file). SKIP rows have nothing"
    echo "to test on this build yet."
    echo ""
    echo "P0 rows (must all be PASS to promote this image): 1 2 3 4 5 7 8 14"
    echo "Per docs/HARDWARE_TEST_MATRIX.md classification: Boot/Root/SSH/Wi-Fi/"
    echo "Display/Touch/Power/Storage."
    echo ""
    echo "Regression rule (per project spec): an image that boots but has LOST a"
    echo "P0 or P1 capability present in baseline/current-system/ is a FAIL for"
    echo "that row even if it 'mostly works'. Cross-check with:"
    echo "  python3 scripts/compare-baselines.py --baseline baseline/current-system \\"
    echo "    --candidate ${EVID} --output ${EVID}/comparison-report.json \\"
    echo "    --human ${EVID}/comparison-report.txt"
    echo "  (NOTE: compare-baselines.py expects the capture-samwise-baseline.sh"
    echo "  layout; this matrix capture uses a different file layout, so treat"
    echo "  that comparison as best-effort / run it against a"
    echo "  collect-target-test-report.sh capture instead if it errors.)"
} >> "$SUMMARY"

echo ""
echo "=== Capture complete ==="
echo "Evidence directory: $EVID"
echo "Summary:            $SUMMARY"
echo ""
cat "$SUMMARY"
