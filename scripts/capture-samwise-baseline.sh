#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BASELINE_DIR="$PROJECT_ROOT/baseline/current-system"
CHECKSUM_DIR="$PROJECT_ROOT/baseline/checksums"

usage() {
    cat <<'USAGE'
Usage: capture-samwise-baseline.sh --host <user@host> [--port <port>] [--output-dir <path>]

Capture a read-only baseline snapshot from the known-good samwise system.
This script does NOT modify the target system in any way.

Options:
  --host <user@host>    SSH target (required)
  --port <port>         SSH port (default: 22)
  --output-dir <path>   Override output directory (default: baseline/current-system/)
  -h, --help            Show this help
USAGE
    exit "${1:-0}"
}

SSH_HOST=""
SSH_PORT=22
OUTPUT_DIR=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --host) SSH_HOST="$2"; shift 2 ;;
        --port) SSH_PORT="$2"; shift 2 ;;
        --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
        -h|--help) usage 0 ;;
        *) echo "Unknown option: $1"; usage 1 ;;
    esac
done

if [[ -z "$SSH_HOST" ]]; then
    echo "ERROR: --host is required"
    usage 1
fi

if [[ -n "$OUTPUT_DIR" ]]; then
    BASELINE_DIR="$OUTPUT_DIR"
fi

SSH_CMD=(ssh -p "$SSH_PORT" -o ConnectTimeout=10 -o BatchMode=yes "$SSH_HOST")
SCP_CMD=(scp -P "$SSH_PORT" -o ConnectTimeout=10 -o BatchMode=yes)

echo "=== Samwise Baseline Capture ==="
echo "Target: $SSH_HOST:$SSH_PORT"
echo "Output: $BASELINE_DIR"
echo "Date:   $(date -Iseconds)"
echo ""

# Verify connectivity
echo "Checking SSH connectivity..."
if ! "${SSH_CMD[@]}" "echo ok" &>/dev/null; then
    echo "ERROR: Cannot connect to $SSH_HOST on port $SSH_PORT"
    echo "Ensure SSH is running and key-based auth is configured."
    exit 1
fi
echo "Connected."
echo ""

mkdir -p "$BASELINE_DIR"/{device-tree,boot,sysfs,hardware-test-reference}
mkdir -p "$CHECKSUM_DIR"

run_remote() {
    local desc="$1"
    local cmd="$2"
    local outfile="$3"

    printf "  Collecting: %-45s" "$desc"
    if "${SSH_CMD[@]}" "$cmd" > "$BASELINE_DIR/$outfile" 2>/dev/null; then
        printf " [OK]\n"
    else
        printf " [SKIP]\n"
    fi
}

# --- Identity ---
echo "--- Identity ---"
run_remote "hostname"            "hostname"                      "hostname.txt"
run_remote "OS release"          "cat /etc/os-release"           "os-release.txt"
run_remote "uname -a"           "uname -a"                      "uname.txt"
run_remote "CPU info"           "lscpu 2>/dev/null || cat /proc/cpuinfo" "cpuinfo.txt"
run_remote "Memory"             "free -h"                       "memory.txt"
run_remote "Machine ID"         "cat /etc/machine-id 2>/dev/null || echo n/a" "machine-id.txt"

# --- Boot ---
echo "--- Boot ---"
run_remote "Kernel cmdline"     "cat /proc/cmdline"             "cmdline.txt"
run_remote "Boot mount"         "mount | grep -E '/boot|/dev/mmcblk'" "boot-mounts.txt"
run_remote "Boot file list"     "ls -la /boot/ 2>/dev/null"     "boot/listing.txt"
run_remote "extlinux.conf"      "cat /boot/extlinux/extlinux.conf 2>/dev/null || echo 'not found'" "boot/extlinux.conf"
run_remote "U-Boot env"         "fw_printenv 2>/dev/null || echo 'fw_printenv not available'" "boot/uboot-env.txt"

# --- Storage ---
echo "--- Storage ---"
run_remote "lsblk"              "lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,MODEL,SERIAL,UUID" "lsblk.txt"
run_remote "blkid"              "blkid 2>/dev/null || echo 'requires root'" "blkid.txt"
run_remote "findmnt"            "findmnt --real"                "mount-map.txt"
run_remote "fstab"              "cat /etc/fstab"                "fstab.txt"
run_remote "df"                 "df -h"                         "df.txt"

# --- Kernel ---
echo "--- Kernel ---"
run_remote "Kernel version"     "uname -r"                      "kernel-version.txt"
run_remote "Kernel config"      "zcat /proc/config.gz 2>/dev/null || echo 'not available'" "kernel-config.txt"
run_remote "Module list"        "lsmod | sort"                  "modules.txt"
run_remote "Module tree version" "ls /lib/modules/ 2>/dev/null" "module-tree-versions.txt"
run_remote "dmesg (boot)"       "dmesg 2>/dev/null | head -500" "dmesg-boot.txt"
run_remote "dmesg (full)"       "dmesg 2>/dev/null"             "dmesg-full.txt"

# --- Device Tree ---
echo "--- Device Tree ---"
run_remote "DT model"           "cat /proc/device-tree/model 2>/dev/null; echo" "device-tree/model.txt"
run_remote "DT compatible"      "cat /proc/device-tree/compatible 2>/dev/null | tr '\0' '\n'" "device-tree/compatible.txt"
run_remote "DT name"            "cat /proc/device-tree/name 2>/dev/null; echo"  "device-tree/name.txt"

printf "  Collecting: %-45s" "Raw FDT blob"
if "${SSH_CMD[@]}" "cat /sys/firmware/fdt 2>/dev/null" > "$BASELINE_DIR/device-tree/fdt.dtb" 2>/dev/null; then
    if [[ -s "$BASELINE_DIR/device-tree/fdt.dtb" ]]; then
        printf " [OK]\n"
        if command -v dtc &>/dev/null; then
            printf "  Collecting: %-45s" "Decompiled DTS"
            dtc -I dtb -O dts -o "$BASELINE_DIR/device-tree/fdt.dts" "$BASELINE_DIR/device-tree/fdt.dtb" 2>/dev/null && printf " [OK]\n" || printf " [SKIP]\n"
        fi
    else
        rm -f "$BASELINE_DIR/device-tree/fdt.dtb"
        printf " [SKIP]\n"
    fi
else
    rm -f "$BASELINE_DIR/device-tree/fdt.dtb"
    printf " [SKIP]\n"
fi

run_remote "DT chosen node"     "ls /proc/device-tree/chosen/ 2>/dev/null" "device-tree/chosen-listing.txt"
run_remote "DT chosen bootargs" "cat /proc/device-tree/chosen/bootargs 2>/dev/null; echo" "device-tree/chosen-bootargs.txt"

# --- Display ---
echo "--- Display ---"
run_remote "DRM devices"        "ls -la /dev/dri/ 2>/dev/null"  "sysfs/drm-devices.txt"
run_remote "DRM connectors"     "find /sys/class/drm/ -maxdepth 2 -name status -exec sh -c 'echo \"\$1: \$(cat \"\$1\")\"' _ {} \\;" "sysfs/drm-connectors.txt"
run_remote "DRM modes"          "find /sys/class/drm/ -maxdepth 2 -name modes -exec sh -c 'echo \"\$1:\"; cat \"\$1\"' _ {} \\;" "sysfs/drm-modes.txt"
run_remote "Backlight"          "find /sys/class/backlight/ -maxdepth 2 \\( -name brightness -o -name max_brightness -o -name actual_brightness \\) -exec sh -c 'echo \"\$1: \$(cat \"\$1\")\"' _ {} \\;" "sysfs/backlight.txt"
run_remote "Panel info"         "find /sys/class/drm/ -name 'card*-DSI*' -exec ls {} \\; 2>/dev/null" "sysfs/panel-info.txt"

# --- Touch / Input ---
echo "--- Touch / Input ---"
run_remote "Input devices"      "cat /proc/bus/input/devices"   "input-devices.txt"
run_remote "Event devices"      "ls -la /dev/input/ 2>/dev/null" "input-event-devices.txt"

# --- Network ---
echo "--- Network ---"
run_remote "Network interfaces" "ip link show"                  "network-interfaces.txt"
run_remote "IP addresses"       "ip addr show"                  "network-addresses.txt"
run_remote "WiFi info"          "iw dev 2>/dev/null || echo 'iw not available'" "wifi-info.txt"
run_remote "WiFi driver"        "readlink /sys/class/net/wlan*/device/driver 2>/dev/null || echo 'n/a'" "wifi-driver.txt"

# --- Power ---
echo "--- Power ---"
run_remote "Power supplies"     "find /sys/class/power_supply/ -maxdepth 2 -type f -exec sh -c 'echo \"\$1: \$(cat \"\$1\" 2>/dev/null)\"' _ {} \\;" "sysfs/power-supplies.txt"
run_remote "Battery status"     "cat /sys/class/power_supply/battery/status 2>/dev/null || cat /sys/class/power_supply/rk-bat/status 2>/dev/null || echo 'n/a'" "sysfs/battery-status.txt"
run_remote "Battery capacity"   "cat /sys/class/power_supply/battery/capacity 2>/dev/null || cat /sys/class/power_supply/rk-bat/capacity 2>/dev/null || echo 'n/a'" "sysfs/battery-capacity.txt"

# --- Sensors ---
echo "--- Sensors ---"
run_remote "IIO devices"        "find /sys/bus/iio/devices/ -maxdepth 2 -name name -exec sh -c 'echo \"\$(dirname \"\$1\"): \$(cat \"\$1\")\"' _ {} \\; 2>/dev/null" "sysfs/iio-devices.txt"
run_remote "DA223/Mir3DA"       "systemctl status mir3da-monitor.service 2>/dev/null || echo 'service not found'" "sysfs/mir3da-status.txt"

# --- Thermal ---
echo "--- Thermal ---"
run_remote "Thermal zones"      "find /sys/class/thermal/thermal_zone* -maxdepth 1 -name type -exec sh -c 'echo \"\$(dirname \"\$1\"): type=\$(cat \"\$1\") temp=\$(cat \"\$(dirname \"\$1\")/temp\" 2>/dev/null)\"' _ {} \\; 2>/dev/null" "sysfs/thermal-zones.txt"

# --- Audio ---
echo "--- Audio ---"
run_remote "ALSA devices"       "aplay -l 2>/dev/null || echo 'aplay not available'" "audio-devices.txt"
run_remote "ALSA cards"         "cat /proc/asound/cards 2>/dev/null || echo 'n/a'" "audio-cards.txt"

# --- Acceleration / Media ---
echo "--- Acceleration / Media ---"
run_remote "GPU devices"        "ls -la /dev/dri/ /dev/mali* 2>/dev/null || echo 'n/a'" "sysfs/gpu-devices.txt"
run_remote "MPP service"        "ls -la /dev/mpp_service 2>/dev/null || echo 'n/a'" "sysfs/mpp-service.txt"
run_remote "RGA device"         "ls -la /dev/rga 2>/dev/null || echo 'n/a'" "sysfs/rga-device.txt"
run_remote "NPU devfreq"        "find /sys/class/devfreq/ -name '*npu*' -exec sh -c 'echo \"\$1: governor=\$(cat \"\$1/governor\" 2>/dev/null) cur_freq=\$(cat \"\$1/cur_freq\" 2>/dev/null)\"' _ {} \\; 2>/dev/null" "sysfs/npu-devfreq.txt"
run_remote "RKNN device"        "ls -la /dev/rknpu* 2>/dev/null || echo 'n/a'" "sysfs/rknn-device.txt"
run_remote "RKNPU driver ver"   "sudo -n cat /sys/kernel/debug/rknpu/version 2>/dev/null || cat /sys/kernel/debug/rknpu/version 2>/dev/null || dmesg 2>/dev/null | grep -i 'rknpu.*driver' || echo 'n/a (debugfs needs root)'" "sysfs/rknpu-driver-version.txt"
run_remote "librknnrt version"  "f=\$(find /usr/lib /usr/lib64 /usr/local/lib /oem -name 'librknnrt.so*' 2>/dev/null | head -1); if [ -n \"\$f\" ]; then echo \"\$f\"; grep -aoh 'librknnrt version[^)]*)' \"\$f\" | head -1; else echo 'n/a'; fi" "sysfs/librknnrt-version.txt"
run_remote "RKLLM runtime"      "f=\$(find /usr/lib /usr/lib64 /usr/local/lib /oem -name 'librkllmrt.so*' 2>/dev/null | head -1); if [ -n \"\$f\" ]; then echo \"\$f\"; grep -aoh 'rkllm-runtime[^,)]*' \"\$f\" | head -1; else echo 'n/a'; fi" "sysfs/rkllm-runtime.txt"

# --- Userland Services ---
echo "--- Userland Services ---"
run_remote "Systemd units"      "systemctl list-units --type=service --state=running --no-pager 2>/dev/null" "services-running.txt"
run_remote "Failed units"       "systemctl list-units --state=failed --no-pager 2>/dev/null" "services-failed.txt"

# --- Generate manifest ---
echo ""
echo "Generating baseline manifest..."
CAPTURE_DATE="$(date -Iseconds)"
cat > "$BASELINE_DIR/manifest.json" <<MANIFEST
{
  "capture_type": "samwise-baseline",
  "capture_date": "$CAPTURE_DATE",
  "target_host": "$SSH_HOST",
  "target_port": $SSH_PORT,
  "capture_script": "capture-samwise-baseline.sh",
  "capture_host": "$(hostname)",
  "notes": "Read-only baseline capture from known-good system"
}
MANIFEST

# --- Compute checksums ---
echo "Computing checksums..."
find "$BASELINE_DIR" -type f -not -path "*/checksums/*" | sort | while read -r f; do
    sha256sum "$f"
done > "$CHECKSUM_DIR/baseline.sha256"

FILE_COUNT=$(find "$BASELINE_DIR" -type f | wc -l)
echo ""
echo "=== Baseline Capture Complete ==="
echo "Files captured: $FILE_COUNT"
echo "Output:         $BASELINE_DIR"
echo "Checksums:      $CHECKSUM_DIR/baseline.sha256"
echo ""
echo "Next steps:"
echo "  1. Review captured evidence for completeness"
echo "  2. Commit baseline to repository"
echo "  3. Verify known-good card image checksum"
echo "  4. Proceed to Phase 1: Boot-Chain Discovery"
