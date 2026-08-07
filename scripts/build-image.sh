#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORK_DIR="$PROJECT_ROOT/work"
ARTIFACTS_DIR="$PROJECT_ROOT/artifacts"
PROFILES_DIR="$PROJECT_ROOT/platform/armbian/profiles"

usage() {
    cat <<'USAGE'
Usage: build-image.sh --profile <name> [options]

Build a platform image through the Armbian Build Framework.

Options:
  --profile <name>    Build profile (required: samwise-minimal, samwise-hardware-test, samwise-tablet-dev)
  --clean             Clean worktree before build
  --docker            Force containerized build (default)
  --native            Use native host build instead of container
  --dry-run           Prepare worktree but do not build
  -h, --help          Show this help
USAGE
    exit "${1:-0}"
}

PROFILE=""
CLEAN=0
BUILD_MODE="docker"
DRY_RUN=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --profile) PROFILE="$2"; shift 2 ;;
        --clean) CLEAN=1; shift ;;
        --docker) BUILD_MODE="docker"; shift ;;
        --native) BUILD_MODE="native"; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help) usage 0 ;;
        *) echo "Unknown option: $1"; usage 1 ;;
    esac
done

if [[ -z "$PROFILE" ]]; then
    echo "ERROR: --profile is required"
    usage 1
fi

PROFILE_FILE="$PROFILES_DIR/${PROFILE}.env"
if [[ ! -f "$PROFILE_FILE" ]]; then
    echo "ERROR: Profile not found: $PROFILE_FILE"
    echo "Available profiles:"
    ls "$PROFILES_DIR/"*.env 2>/dev/null | xargs -I{} basename {} .env | sed 's/^/  /' || echo "  (none)"
    exit 1
fi

echo "=== Samwise Platform Image Build ==="
echo "Profile: $PROFILE"
echo "Mode:    $BUILD_MODE"
echo "Date:    $(date -Iseconds)"
echo ""

# Run host preflight
echo "--- Host Preflight ---"
if ! "$SCRIPT_DIR/host-preflight.sh"; then
    echo "ERROR: Host preflight failed. Fix issues before building."
    exit 1
fi
echo ""

# Prepare worktree
echo "--- Worktree Preparation ---"
PREP_ARGS=(--profile "$PROFILE")
if (( CLEAN )); then
    PREP_ARGS+=(--clean)
fi
"$SCRIPT_DIR/prepare-armbian-worktree.sh" "${PREP_ARGS[@]}"
echo ""

WORKTREE="$WORK_DIR/armbian-build"

if (( DRY_RUN )); then
    echo "Dry run — worktree prepared but build not started."
    echo "Worktree: $WORKTREE"
    exit 0
fi

# Source profile to get build parameters
set -a
# shellcheck disable=SC1090
source "$PROFILE_FILE"
set +a

# Create artifact output directories
BUILD_TS="$(date +%Y%m%d-%H%M%S)"
BUILD_ARTIFACT_DIR="$ARTIFACTS_DIR/${PROFILE}_${BUILD_TS}"
mkdir -p "$BUILD_ARTIFACT_DIR"/{images,kernel,boot,dtb,logs}

# Build
echo "--- Building Image ---"
echo "Armbian build directory: $WORKTREE"
echo "Artifact output: $BUILD_ARTIFACT_DIR"
echo ""

BUILD_LOG="$BUILD_ARTIFACT_DIR/logs/build.log"

ARMBIAN_BUILD_CMD=("$WORKTREE/compile.sh")

# Map profile settings to Armbian compile.sh arguments
ARMBIAN_ARGS=()
[[ -n "${ARMBIAN_BOARD:-}" ]] && ARMBIAN_ARGS+=(BOARD="$ARMBIAN_BOARD")
[[ -n "${ARMBIAN_BRANCH:-}" ]] && ARMBIAN_ARGS+=(BRANCH="$ARMBIAN_BRANCH")
[[ -n "${ARMBIAN_RELEASE:-}" ]] && ARMBIAN_ARGS+=(RELEASE="$ARMBIAN_RELEASE")
[[ -n "${ARMBIAN_BUILD_DESKTOP:-}" ]] && ARMBIAN_ARGS+=(BUILD_DESKTOP="$ARMBIAN_BUILD_DESKTOP")
[[ -n "${ARMBIAN_BUILD_MINIMAL:-}" ]] && ARMBIAN_ARGS+=(BUILD_MINIMAL="$ARMBIAN_BUILD_MINIMAL")
[[ -n "${ARMBIAN_KERNEL_CONFIGURE:-}" ]] && ARMBIAN_ARGS+=(KERNEL_CONFIGURE="$ARMBIAN_KERNEL_CONFIGURE")

echo "Armbian args: ${ARMBIAN_ARGS[*]:-none}"
echo "Build log: $BUILD_LOG"
echo ""

if [[ "$BUILD_MODE" == "docker" ]]; then
    ARMBIAN_ARGS+=(DOCKER_ARMBIAN=yes)
fi

set -o pipefail
if "${ARMBIAN_BUILD_CMD[@]}" "${ARMBIAN_ARGS[@]}" 2>&1 | tee "$BUILD_LOG"; then
    echo ""
    echo "Build completed successfully."
else
    BUILD_EXIT=$?
    echo ""
    echo "ERROR: Build failed with exit code $BUILD_EXIT"
    echo "Check log: $BUILD_LOG"
    exit "$BUILD_EXIT"
fi

# Collect artifacts
echo ""
echo "--- Collecting Artifacts ---"

ARMBIAN_OUTPUT="$WORKTREE/output"
if [[ -d "$ARMBIAN_OUTPUT/images" ]]; then
    cp "$ARMBIAN_OUTPUT/images/"*.img* "$BUILD_ARTIFACT_DIR/images/" 2>/dev/null || true
fi
if [[ -d "$ARMBIAN_OUTPUT/debs" ]]; then
    cp "$ARMBIAN_OUTPUT/debs/"*kernel* "$BUILD_ARTIFACT_DIR/kernel/" 2>/dev/null || true
    cp "$ARMBIAN_OUTPUT/debs/"*dtb* "$BUILD_ARTIFACT_DIR/dtb/" 2>/dev/null || true
fi

# Generate checksums
echo "Computing checksums..."
find "$BUILD_ARTIFACT_DIR/images" -type f | while read -r f; do
    sha256sum "$f" >> "$BUILD_ARTIFACT_DIR/images/SHA256SUMS"
done

# Generate manifest
echo "Generating manifest..."
ARMBIAN_COMMIT="$(git -C "$PROJECT_ROOT/third_party/armbian-build" rev-parse HEAD 2>/dev/null || echo 'unknown')"
OVERLAY_REV="$(git -C "$PROJECT_ROOT" rev-parse HEAD 2>/dev/null || echo 'unknown')"

IMAGE_FILE=$(find "$BUILD_ARTIFACT_DIR/images" -name "*.img*" -not -name "*.sha256" -not -name "SHA256SUMS" | head -1)
IMAGE_SHA256=""
if [[ -n "$IMAGE_FILE" ]]; then
    IMAGE_SHA256="$(sha256sum "$IMAGE_FILE" | awk '{print $1}')"
fi

cat > "$BUILD_ARTIFACT_DIR/images/${PROFILE}_${BUILD_TS}.manifest.json" <<MANIFEST
{
  "project": "rk3562deb",
  "target": "samwise",
  "profile": "$PROFILE",
  "created_at": "$(date -Iseconds)",
  "armbian_build_commit": "$ARMBIAN_COMMIT",
  "kernel_source": {"url": "see source-lock/kernel.lock", "commit": "see lockfile"},
  "uboot_source": {"url": "see source-lock/u-boot.lock", "commit": "see lockfile"},
  "device_tree": {"source_hash": "pending", "dtb_hash": "pending"},
  "overlay_revision": "$OVERLAY_REV",
  "rootfs_release": "${ARMBIAN_RELEASE:-bookworm}",
  "host": {"os": "$(lsb_release -ds 2>/dev/null || echo unknown)", "arch": "$(uname -m)"},
  "toolchain": {"compiler": "armbian-managed", "version": "see build log"},
  "image_sha256": "$IMAGE_SHA256",
  "eMMC_write_policy": "forbidden",
  "test_status": "not-tested"
}
MANIFEST

echo ""
echo "=== Build Complete ==="
echo "Artifacts: $BUILD_ARTIFACT_DIR"
echo "Manifest:  $BUILD_ARTIFACT_DIR/images/${PROFILE}_${BUILD_TS}.manifest.json"
echo ""
echo "Next steps:"
echo "  1. ./scripts/verify-artifact.sh --image <image> --manifest <manifest>"
echo "  2. ./scripts/flash-image-safely.sh --image <image> --target /dev/sdX"
