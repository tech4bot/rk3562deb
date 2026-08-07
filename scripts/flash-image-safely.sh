#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

usage() {
    cat <<'USAGE'
Usage: flash-image-safely.sh --image <image.img or .img.xz> --target <device>

Flash a verified candidate image to a removable microSD card.

SAFETY:
  - Will NEVER write to eMMC (mmcblk2 is blocked)
  - Requires explicit target device
  - Shows device details and requires confirmation
  - Runs verify-artifact.sh before flashing

Options:
  --image <path>    Image file to flash (.img or .img.xz)
  --target <dev>    Target block device (e.g., /dev/sdb)
  --manifest <path> Manifest JSON for pre-flash verification
  --skip-verify     Skip artifact verification (not recommended)
  -h, --help        Show this help
USAGE
    exit "${1:-0}"
}

IMAGE=""
TARGET=""
MANIFEST=""
SKIP_VERIFY=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --image) IMAGE="$2"; shift 2 ;;
        --target) TARGET="$2"; shift 2 ;;
        --manifest) MANIFEST="$2"; shift 2 ;;
        --skip-verify) SKIP_VERIFY=1; shift ;;
        -h|--help) usage 0 ;;
        *) echo "Unknown option: $1"; usage 1 ;;
    esac
done

if [[ -z "$IMAGE" || -z "$TARGET" ]]; then
    echo "ERROR: --image and --target are required"
    usage 1
fi

# === eMMC PROTECTION ===
EMMC_BLOCKED_PATTERNS=(
    "mmcblk2"
    "mmcblk2p"
)

TARGET_BASENAME="$(basename "$TARGET")"
for pattern in "${EMMC_BLOCKED_PATTERNS[@]}"; do
    if [[ "$TARGET_BASENAME" == *"$pattern"* ]]; then
        printf "${RED}FATAL: Target device '%s' matches eMMC pattern '%s'${NC}\n" "$TARGET" "$pattern"
        printf "${RED}eMMC writes are FORBIDDEN in this project phase.${NC}\n"
        echo "Use a removable microSD card only."
        exit 99
    fi
done

# Additional eMMC size guard — the known tablet eMMC is ~116.5 GiB
if [[ -b "$TARGET" ]]; then
    TARGET_SIZE_BYTES=$(blockdev --getsize64 "$TARGET" 2>/dev/null || echo 0)
    TARGET_SIZE_GB=$(( TARGET_SIZE_BYTES / 1024 / 1024 / 1024 ))
    if (( TARGET_SIZE_GB > 100 && TARGET_SIZE_GB < 130 )); then
        printf "${RED}FATAL: Target device '%s' is %d GiB — matches known eMMC size range${NC}\n" "$TARGET" "$TARGET_SIZE_GB"
        printf "${RED}Refusing to flash. Use a removable microSD card.${NC}\n"
        exit 99
    fi
fi

# Check target is a block device
if [[ ! -b "$TARGET" ]]; then
    echo "ERROR: $TARGET is not a block device"
    exit 1
fi

# Check image exists
if [[ ! -f "$IMAGE" ]]; then
    echo "ERROR: Image file not found: $IMAGE"
    exit 1
fi

# Run artifact verification
if (( SKIP_VERIFY == 0 )); then
    if [[ -n "$MANIFEST" ]]; then
        echo "Running artifact verification..."
        if ! "$SCRIPT_DIR/verify-artifact.sh" --image "$IMAGE" --manifest "$MANIFEST"; then
            printf "${RED}Artifact verification FAILED. Refusing to flash.${NC}\n"
            exit 1
        fi
        echo ""
    else
        printf "${YELLOW}WARNING: No manifest provided. Skipping artifact verification.${NC}\n"
        echo "Use --manifest <path> for full verification."
        echo ""
    fi
fi

# Gather target device information
echo "=== Target Device Information ==="
echo ""
printf "  Device:     %s\n" "$TARGET"

if command -v lsblk &>/dev/null; then
    echo ""
    echo "  Block device details:"
    lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,MODEL,SERIAL "$TARGET" 2>/dev/null | sed 's/^/    /'
fi

if command -v udevadm &>/dev/null; then
    REMOVABLE=$(udevadm info --query=property --name="$TARGET" 2>/dev/null | grep -c "ID_BUS=usb" || true)
    if (( REMOVABLE > 0 )); then
        printf "\n  ${GREEN}Device appears to be USB-connected (removable)${NC}\n"
    else
        printf "\n  ${YELLOW}WARNING: Device does not appear to be USB-connected${NC}\n"
    fi
fi

# Check for mounted partitions
MOUNTED_PARTS=$(lsblk -o NAME,MOUNTPOINT "$TARGET" 2>/dev/null | awk 'NR>1 && $2 != "" {print $1 " -> " $2}' || true)
if [[ -n "$MOUNTED_PARTS" ]]; then
    printf "\n  ${YELLOW}WARNING: Partitions are currently mounted:${NC}\n"
    echo "$MOUNTED_PARTS" | sed 's/^/    /'
    echo ""
    echo "  These will need to be unmounted before flashing."
fi

echo ""
printf "  Image:      %s\n" "$IMAGE"
printf "  Image size: %s\n" "$(du -h "$IMAGE" | cut -f1)"

echo ""
printf "${BOLD}${RED}WARNING: This will DESTROY all data on %s${NC}\n" "$TARGET"
echo ""
read -r -p "Type 'yes-flash' to confirm: " CONFIRM

if [[ "$CONFIRM" != "yes-flash" ]]; then
    echo "Aborted."
    exit 1
fi

# Unmount any mounted partitions
if [[ -n "$MOUNTED_PARTS" ]]; then
    echo "Unmounting partitions..."
    for part in "${TARGET}"*; do
        if mountpoint -q "$part" 2>/dev/null || mount | grep -q "^$part "; then
            umount "$part" 2>/dev/null || true
        fi
    done
fi

# Flash
echo ""
echo "Flashing image..."
if [[ "$IMAGE" == *.xz ]]; then
    echo "Decompressing and writing..."
    xz -dc "$IMAGE" | dd of="$TARGET" bs=4M status=progress conv=fsync
elif [[ "$IMAGE" == *.img ]]; then
    dd if="$IMAGE" of="$TARGET" bs=4M status=progress conv=fsync
else
    echo "ERROR: Unsupported image format. Use .img or .img.xz"
    exit 1
fi

sync

echo ""
printf "${GREEN}Flash complete.${NC}\n"
echo ""
echo "Next steps:"
echo "  1. Safely remove the SD card"
echo "  2. Insert into samwise tablet"
echo "  3. Power on and observe boot"
echo "  4. Run: ./scripts/collect-target-test-report.sh --host frodo@samwise"
