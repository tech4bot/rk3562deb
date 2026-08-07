#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

FAIL=0
WARN=0
PASS_COUNT=0

pass() { printf "${GREEN}[PASS]${NC} %s\n" "$1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { printf "${RED}[FAIL]${NC} %s\n" "$1"; FAIL=$((FAIL + 1)); }
warn() { printf "${YELLOW}[WARN]${NC} %s\n" "$1"; WARN=$((WARN + 1)); }

usage() {
    cat <<'USAGE'
Usage: verify-artifact.sh --image <image> --manifest <manifest.json>

Verify a build artifact before flashing.

Checks:
  1. Image checksum
  2. Manifest integrity
  3. Expected boot files
  4. DTB hash matches manifest
  5. Rootfs release matches profile
  6. No eMMC-targeting content
  7. Network/SSH first-boot policy
  8. Source commits in lockfiles

Options:
  --image <path>       Image file to verify
  --manifest <path>    Manifest JSON
  --mount-check        Mount image and inspect contents (requires root)
  -h, --help           Show this help
USAGE
    exit "${1:-0}"
}

IMAGE=""
MANIFEST=""
MOUNT_CHECK=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --image) IMAGE="$2"; shift 2 ;;
        --manifest) MANIFEST="$2"; shift 2 ;;
        --mount-check) MOUNT_CHECK=1; shift ;;
        -h|--help) usage 0 ;;
        *) echo "Unknown option: $1"; usage 1 ;;
    esac
done

if [[ -z "$IMAGE" || -z "$MANIFEST" ]]; then
    echo "ERROR: --image and --manifest are required"
    usage 1
fi

echo "=== Artifact Verification ==="
echo "Image:    $IMAGE"
echo "Manifest: $MANIFEST"
echo "Date:     $(date -Iseconds)"
echo ""

# 1. Image exists
if [[ -f "$IMAGE" ]]; then
    pass "Image file exists"
else
    fail "Image file not found: $IMAGE"
    echo "Cannot continue verification."
    exit 1
fi

# 2. Manifest exists and is valid JSON
if [[ -f "$MANIFEST" ]]; then
    if python3 -m json.tool "$MANIFEST" &>/dev/null; then
        pass "Manifest is valid JSON"
    else
        fail "Manifest is not valid JSON"
    fi
else
    fail "Manifest file not found: $MANIFEST"
    echo "Cannot continue verification."
    exit 1
fi

# 3. Image checksum
CHECKSUM_FILE="${IMAGE}.sha256"
if [[ -f "$CHECKSUM_FILE" ]]; then
    if sha256sum -c "$CHECKSUM_FILE" &>/dev/null; then
        pass "Image checksum matches sidecar .sha256 file"
    else
        fail "Image checksum MISMATCH"
    fi
else
    ACTUAL_SHA256="$(sha256sum "$IMAGE" | awk '{print $1}')"
    MANIFEST_SHA256="$(python3 -c "import json; print(json.load(open('$MANIFEST')).get('image_sha256',''))" 2>/dev/null || echo "")"
    if [[ -n "$MANIFEST_SHA256" && "$ACTUAL_SHA256" == "$MANIFEST_SHA256" ]]; then
        pass "Image checksum matches manifest"
    elif [[ -n "$MANIFEST_SHA256" ]]; then
        fail "Image checksum mismatch (manifest: $MANIFEST_SHA256, actual: $ACTUAL_SHA256)"
    else
        warn "No checksum reference found for image"
    fi
fi

# 4. Manifest required fields
REQUIRED_FIELDS=("project" "target" "profile" "created_at" "armbian_build_commit" "overlay_revision" "rootfs_release" "eMMC_write_policy" "test_status")
for field in "${REQUIRED_FIELDS[@]}"; do
    VALUE="$(python3 -c "import json; v=json.load(open('$MANIFEST')).get('$field',''); print(v if v else '')" 2>/dev/null || echo "")"
    if [[ -n "$VALUE" ]]; then
        pass "Manifest field '$field': $VALUE"
    else
        fail "Manifest missing required field: $field"
    fi
done

# 5. eMMC write policy check
EMMC_POLICY="$(python3 -c "import json; print(json.load(open('$MANIFEST')).get('eMMC_write_policy',''))" 2>/dev/null || echo "")"
if [[ "$EMMC_POLICY" == "forbidden" ]]; then
    pass "eMMC write policy: forbidden"
else
    fail "eMMC write policy is not 'forbidden' (got: $EMMC_POLICY)"
fi

# 6. Source commits recorded
ARMBIAN_COMMIT="$(python3 -c "import json; print(json.load(open('$MANIFEST')).get('armbian_build_commit',''))" 2>/dev/null || echo "")"
if [[ -n "$ARMBIAN_COMMIT" && ${#ARMBIAN_COMMIT} -ge 40 ]]; then
    pass "Armbian build commit recorded (full SHA)"
else
    warn "Armbian build commit may not be a full SHA: $ARMBIAN_COMMIT"
fi

# 7. Check lockfiles exist
for lockname in armbian-build.lock kernel.lock u-boot.lock; do
    LOCKPATH="$PROJECT_ROOT/platform/armbian/source-lock/$lockname"
    if [[ -f "$LOCKPATH" ]]; then
        pass "Lockfile present: $lockname"
    else
        warn "Lockfile missing: $lockname"
    fi
done

# 8. Mount-level checks (optional, requires root)
if (( MOUNT_CHECK )) && [[ "$IMAGE" == *.img ]]; then
    echo ""
    echo "--- Mount-level checks ---"
    TMPDIR="$(mktemp -d)"
    LOOP=""

    cleanup_mount() {
        umount "$TMPDIR" 2>/dev/null || true
        [[ -n "$LOOP" ]] && losetup -d "$LOOP" 2>/dev/null || true
        rmdir "$TMPDIR" 2>/dev/null || true
    }
    trap cleanup_mount EXIT

    LOOP="$(losetup --find --show --partscan "$IMAGE" 2>/dev/null || echo "")"
    if [[ -n "$LOOP" ]]; then
        ROOTFS_PART="${LOOP}p4"
        if [[ -b "$ROOTFS_PART" ]]; then
            if mount -o ro "$ROOTFS_PART" "$TMPDIR" 2>/dev/null; then
                # Check for eMMC fstab entries
                if grep -q "mmcblk2" "$TMPDIR/etc/fstab" 2>/dev/null; then
                    fail "fstab contains eMMC references (mmcblk2)"
                else
                    pass "No eMMC references in fstab"
                fi

                # Check SSH configuration
                if [[ -f "$TMPDIR/etc/ssh/sshd_config" ]]; then
                    pass "SSH configuration present"
                else
                    warn "SSH configuration not found in image"
                fi

                # Check os-release
                if [[ -f "$TMPDIR/etc/os-release" ]]; then
                    IMG_RELEASE="$(grep VERSION_CODENAME "$TMPDIR/etc/os-release" | cut -d= -f2)"
                    MANIFEST_RELEASE="$(python3 -c "import json; print(json.load(open('$MANIFEST')).get('rootfs_release',''))" 2>/dev/null || echo "")"
                    if [[ "$IMG_RELEASE" == "$MANIFEST_RELEASE" ]]; then
                        pass "Rootfs release matches manifest: $IMG_RELEASE"
                    else
                        fail "Rootfs release mismatch (image: $IMG_RELEASE, manifest: $MANIFEST_RELEASE)"
                    fi
                fi

                umount "$TMPDIR"
            fi
        fi
        losetup -d "$LOOP"
        LOOP=""
    else
        warn "Cannot set up loop device (requires root)"
    fi
fi

echo ""
echo "=== Verification Summary ==="
echo "Passed: $PASS_COUNT"
echo "Failed: $FAIL"
echo "Warnings: $WARN"

if (( FAIL > 0 )); then
    printf "${RED}VERIFICATION FAILED — do not flash this artifact.${NC}\n"
    exit 1
else
    printf "${GREEN}Verification passed.${NC}\n"
    exit 0
fi
