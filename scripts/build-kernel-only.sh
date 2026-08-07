#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORK_DIR="$PROJECT_ROOT/work"
ARTIFACTS_DIR="$PROJECT_ROOT/artifacts"
PROFILES_DIR="$PROJECT_ROOT/platform/armbian/profiles"

usage() {
    cat <<'USAGE'
Usage: build-kernel-only.sh --profile <name> [options]

Build only the kernel through the Armbian Build Framework.
Produces kernel packages, DTB, and boot artifacts without a full image.

Options:
  --profile <name>    Build profile (required)
  --clean             Clean worktree before build
  -h, --help          Show this help
USAGE
    exit "${1:-0}"
}

PROFILE=""
CLEAN=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --profile) PROFILE="$2"; shift 2 ;;
        --clean) CLEAN=1; shift ;;
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
    exit 1
fi

echo "=== Samwise Kernel-Only Build ==="
echo "Profile: $PROFILE"
echo "Date:    $(date -Iseconds)"
echo ""

# Prepare worktree
PREP_ARGS=(--profile "$PROFILE")
(( CLEAN )) && PREP_ARGS+=(--clean)
"$SCRIPT_DIR/prepare-armbian-worktree.sh" "${PREP_ARGS[@]}"

WORKTREE="$WORK_DIR/armbian-build"

set -a
# shellcheck disable=SC1090
source "$PROFILE_FILE"
set +a

BUILD_TS="$(date +%Y%m%d-%H%M%S)"
BUILD_ARTIFACT_DIR="$ARTIFACTS_DIR/kernel_${PROFILE}_${BUILD_TS}"
mkdir -p "$BUILD_ARTIFACT_DIR"/{kernel,dtb,boot,logs}

BUILD_LOG="$BUILD_ARTIFACT_DIR/logs/kernel-build.log"

ARMBIAN_ARGS=()
[[ -n "${ARMBIAN_BOARD:-}" ]] && ARMBIAN_ARGS+=(BOARD="$ARMBIAN_BOARD")
[[ -n "${ARMBIAN_BRANCH:-}" ]] && ARMBIAN_ARGS+=(BRANCH="$ARMBIAN_BRANCH")
ARMBIAN_ARGS+=(KERNEL_ONLY=yes)
ARMBIAN_ARGS+=(KERNEL_CONFIGURE="${ARMBIAN_KERNEL_CONFIGURE:-no}")

echo "Building kernel..."
set -o pipefail
if "$WORKTREE/compile.sh" "${ARMBIAN_ARGS[@]}" 2>&1 | tee "$BUILD_LOG"; then
    echo "Kernel build completed."
else
    echo "ERROR: Kernel build failed."
    exit 1
fi

# Collect kernel artifacts
ARMBIAN_OUTPUT="$WORKTREE/output"
if [[ -d "$ARMBIAN_OUTPUT/debs" ]]; then
    cp "$ARMBIAN_OUTPUT/debs/"*kernel* "$BUILD_ARTIFACT_DIR/kernel/" 2>/dev/null || true
    cp "$ARMBIAN_OUTPUT/debs/"*dtb* "$BUILD_ARTIFACT_DIR/dtb/" 2>/dev/null || true
fi

find "$BUILD_ARTIFACT_DIR" -type f -name "*.deb" -o -name "*.tar*" | while read -r f; do
    sha256sum "$f"
done > "$BUILD_ARTIFACT_DIR/SHA256SUMS"

ARMBIAN_COMMIT="$(git -C "$PROJECT_ROOT/third_party/armbian-build" rev-parse HEAD 2>/dev/null || echo 'unknown')"
OVERLAY_REV="$(git -C "$PROJECT_ROOT" rev-parse HEAD 2>/dev/null || echo 'unknown')"

cat > "$BUILD_ARTIFACT_DIR/kernel-manifest.json" <<MANIFEST
{
  "project": "rk3562deb",
  "target": "samwise",
  "profile": "$PROFILE",
  "build_type": "kernel-only",
  "created_at": "$(date -Iseconds)",
  "armbian_build_commit": "$ARMBIAN_COMMIT",
  "overlay_revision": "$OVERLAY_REV",
  "host": "$(hostname)"
}
MANIFEST

echo ""
echo "=== Kernel Build Complete ==="
echo "Artifacts: $BUILD_ARTIFACT_DIR"
