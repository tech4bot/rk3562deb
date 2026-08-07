#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SYSROOT_DIR="$PROJECT_ROOT/toolchains/sysroot"

usage() {
    cat <<'USAGE'
Usage: export-sdk.sh --artifact <image-manifest.json> [--output <dir>]

Export a versioned application-development SDK from a tested platform image.
The SDK sysroot is derived from the same rootfs used in the verified image.

Options:
  --artifact <path>   Image manifest JSON (from a passing build)
  --output <dir>      SDK output directory (default: toolchains/sysroot/)
  --image <path>      Image file to extract sysroot from
  -h, --help          Show this help
USAGE
    exit "${1:-0}"
}

ARTIFACT=""
IMAGE=""
OUTPUT_DIR=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --artifact) ARTIFACT="$2"; shift 2 ;;
        --image) IMAGE="$2"; shift 2 ;;
        --output) OUTPUT_DIR="$2"; shift 2 ;;
        -h|--help) usage 0 ;;
        *) echo "Unknown option: $1"; usage 1 ;;
    esac
done

if [[ -z "$ARTIFACT" ]]; then
    echo "ERROR: --artifact is required"
    usage 1
fi

[[ -n "$OUTPUT_DIR" ]] && SYSROOT_DIR="$OUTPUT_DIR"

echo "=== SDK Export ==="
echo "Manifest: $ARTIFACT"
echo "Output:   $SYSROOT_DIR"
echo "Date:     $(date -Iseconds)"
echo ""

# Verify manifest
if [[ ! -f "$ARTIFACT" ]]; then
    echo "ERROR: Manifest not found: $ARTIFACT"
    exit 1
fi

TEST_STATUS="$(python3 -c "import json; print(json.load(open('$ARTIFACT')).get('test_status',''))" 2>/dev/null || echo "")"
if [[ "$TEST_STATUS" == "fail" ]]; then
    echo "ERROR: Image test status is 'fail'. Cannot export SDK from a failing image."
    exit 1
fi

if [[ "$TEST_STATUS" == "not-tested" ]]; then
    echo "WARNING: Image has not been tested yet. SDK may not be reliable."
    read -r -p "Continue? [y/N] " CONFIRM
    [[ "$CONFIRM" =~ ^[Yy]$ ]] || exit 1
fi

# Find image
if [[ -z "$IMAGE" ]]; then
    MANIFEST_DIR="$(dirname "$ARTIFACT")"
    IMAGE="$(find "$MANIFEST_DIR" -name "*.img" -o -name "*.img.xz" 2>/dev/null | head -1)"
fi

if [[ -z "$IMAGE" || ! -f "$IMAGE" ]]; then
    echo "ERROR: Cannot find image file. Use --image to specify."
    exit 1
fi

echo "Image: $IMAGE"
echo ""

# Extract sysroot
echo "Extracting sysroot from image..."
TMPDIR="$(mktemp -d)"
trap 'umount "$TMPDIR" 2>/dev/null || true; rm -rf "$TMPDIR"' EXIT

WORK_IMG="$IMAGE"
if [[ "$IMAGE" == *.xz ]]; then
    echo "Decompressing image..."
    WORK_IMG="$TMPDIR/image.img"
    xz -dc "$IMAGE" > "$WORK_IMG"
fi

LOOP="$(losetup --find --show --partscan "$WORK_IMG" 2>/dev/null || echo "")"
if [[ -z "$LOOP" ]]; then
    echo "ERROR: Cannot set up loop device (requires root)"
    exit 1
fi
trap 'umount "$TMPDIR" 2>/dev/null || true; losetup -d "$LOOP" 2>/dev/null || true; rm -rf "$TMPDIR"' EXIT

ROOTFS_PART="${LOOP}p4"
if [[ ! -b "$ROOTFS_PART" ]]; then
    echo "ERROR: Cannot find rootfs partition"
    exit 1
fi

mount -o ro "$ROOTFS_PART" "$TMPDIR"

mkdir -p "$SYSROOT_DIR"/{usr/include,usr/lib/aarch64-linux-gnu,lib/aarch64-linux-gnu,etc}

echo "Copying headers..."
rsync -a "$TMPDIR/usr/include/" "$SYSROOT_DIR/usr/include/"

echo "Copying target libraries..."
rsync -a "$TMPDIR/usr/lib/aarch64-linux-gnu/" "$SYSROOT_DIR/usr/lib/aarch64-linux-gnu/"
rsync -a "$TMPDIR/lib/aarch64-linux-gnu/" "$SYSROOT_DIR/lib/aarch64-linux-gnu/" 2>/dev/null || true

echo "Copying os-release..."
cp "$TMPDIR/etc/os-release" "$SYSROOT_DIR/etc/"

umount "$TMPDIR"
losetup -d "$LOOP"
LOOP=""

# Generate SDK metadata
OVERLAY_REV="$(git -C "$PROJECT_ROOT" rev-parse HEAD 2>/dev/null || echo 'unknown')"

cat > "$SYSROOT_DIR/../sdk-manifest.json" <<MANIFEST
{
  "project": "rk3562deb",
  "target": "samwise",
  "sdk_type": "cross-compilation-sysroot",
  "created_at": "$(date -Iseconds)",
  "source_image_manifest": "$ARTIFACT",
  "overlay_revision": "$OVERLAY_REV",
  "architecture": "aarch64",
  "triple": "aarch64-linux-gnu"
}
MANIFEST

# Generate environment setup script
cat > "$SYSROOT_DIR/../environment-setup-samwise-aarch64.sh" <<'ENVSETUP'
#!/usr/bin/env bash
# Source this file to configure cross-compilation for samwise (aarch64)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export SAMWISE_SYSROOT="$SCRIPT_DIR/sysroot"
export CC=aarch64-linux-gnu-gcc
export CXX=aarch64-linux-gnu-g++
export AR=aarch64-linux-gnu-ar
export STRIP=aarch64-linux-gnu-strip
export PKG_CONFIG_PATH="$SAMWISE_SYSROOT/usr/lib/aarch64-linux-gnu/pkgconfig"
export PKG_CONFIG_SYSROOT_DIR="$SAMWISE_SYSROOT"
echo "Samwise cross-compilation environment configured."
echo "  Sysroot: $SAMWISE_SYSROOT"
echo "  CC:      $CC"
ENVSETUP

chmod +x "$SYSROOT_DIR/../environment-setup-samwise-aarch64.sh"

echo ""
echo "=== SDK Export Complete ==="
echo "Sysroot:     $SYSROOT_DIR"
echo "Manifest:    $SYSROOT_DIR/../sdk-manifest.json"
echo "Env setup:   source $SYSROOT_DIR/../environment-setup-samwise-aarch64.sh"
echo "CMake:       -DCMAKE_TOOLCHAIN_FILE=$PROJECT_ROOT/toolchains/cmake/samwise-aarch64.cmake"
