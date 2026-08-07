#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ARMBIAN_SRC="$PROJECT_ROOT/third_party/armbian-build"
WORK_DIR="$PROJECT_ROOT/work"
OVERLAY_DIR="$PROJECT_ROOT/platform/armbian"
LOCKFILE="$OVERLAY_DIR/source-lock/armbian-build.lock"

usage() {
    cat <<'USAGE'
Usage: prepare-armbian-worktree.sh [--profile <name>] [--clean]

Prepare a disposable Armbian build worktree with the project overlay applied.

Steps:
  1. Verify the pinned Armbian checkout matches the lockfile
  2. Create/clean the build worktree under work/
  3. Copy userpatches overlay into the worktree
  4. Inject the selected build profile
  5. Record resolved source revisions

Options:
  --profile <name>    Build profile to inject (e.g., samwise-minimal)
  --clean             Remove existing worktree before creating
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

echo "=== Armbian Worktree Preparation ==="
echo "Date: $(date -Iseconds)"
echo ""

# Step 1: Verify pinned checkout
echo "--- Step 1: Verify pinned Armbian checkout ---"
if [[ ! -d "$ARMBIAN_SRC/.git" ]]; then
    echo "ERROR: Armbian Build Framework not found at $ARMBIAN_SRC"
    echo "Initialize with:"
    echo "  git submodule update --init third_party/armbian-build"
    echo "  OR"
    echo "  git clone https://github.com/armbian/build.git third_party/armbian-build"
    exit 1
fi

ARMBIAN_COMMIT="$(git -C "$ARMBIAN_SRC" rev-parse HEAD)"
echo "  Armbian commit: $ARMBIAN_COMMIT"

if [[ -f "$LOCKFILE" ]]; then
    LOCKED_COMMIT="$(grep -E '^commit:' "$LOCKFILE" | awk '{print $2}')"
    if [[ -n "$LOCKED_COMMIT" && "$ARMBIAN_COMMIT" != "$LOCKED_COMMIT" ]]; then
        echo "WARNING: Armbian checkout ($ARMBIAN_COMMIT) does not match lockfile ($LOCKED_COMMIT)"
        echo "To update the lockfile, edit: $LOCKFILE"
        echo "To reset checkout: git -C $ARMBIAN_SRC checkout $LOCKED_COMMIT"
        exit 1
    fi
    echo "  Lockfile match: OK"
else
    echo "  WARNING: No lockfile found. Creating initial lockfile."
    mkdir -p "$(dirname "$LOCKFILE")"
    cat > "$LOCKFILE" <<LOCK
repository: armbian/build
commit: $ARMBIAN_COMMIT
retrieval_date: $(date -Iseconds)
verified_by: prepare-armbian-worktree.sh
LOCK
    echo "  Created: $LOCKFILE"
fi

# Check for uncommitted changes in upstream
if ! git -C "$ARMBIAN_SRC" diff --quiet 2>/dev/null; then
    echo "ERROR: Armbian checkout has uncommitted changes."
    echo "The upstream worktree must remain clean."
    echo "Discard changes: git -C $ARMBIAN_SRC checkout ."
    exit 1
fi

# Step 2: Create worktree
WORKTREE="$WORK_DIR/armbian-build"
echo ""
echo "--- Step 2: Prepare build worktree ---"

if (( CLEAN )); then
    echo "  Cleaning existing worktree..."
    rm -rf "$WORKTREE"
fi

if [[ -d "$WORKTREE" ]]; then
    echo "  Worktree exists at $WORKTREE"
    echo "  Use --clean to recreate"
else
    echo "  Creating worktree via rsync..."
    mkdir -p "$WORKTREE"
    rsync -a --exclude='.git' "$ARMBIAN_SRC/" "$WORKTREE/"
    echo "  Worktree created: $WORKTREE"
fi

# Step 3: Copy overlay
echo ""
echo "--- Step 3: Apply project overlay ---"

USERPATCHES_SRC="$OVERLAY_DIR/userpatches"
USERPATCHES_DST="$WORKTREE/userpatches"

if [[ -d "$USERPATCHES_SRC" ]]; then
    mkdir -p "$USERPATCHES_DST"
    rsync -a "$USERPATCHES_SRC/" "$USERPATCHES_DST/"
    echo "  Overlay applied: $USERPATCHES_SRC -> $USERPATCHES_DST"
else
    echo "  WARNING: No userpatches overlay found at $USERPATCHES_SRC"
fi

PATCHES_SRC="$OVERLAY_DIR/patches"
if [[ -d "$PATCHES_SRC" ]] && [[ "$(ls -A "$PATCHES_SRC" 2>/dev/null)" ]]; then
    rsync -a "$PATCHES_SRC/" "$WORKTREE/patch/" 2>/dev/null || true
    echo "  Patches applied from: $PATCHES_SRC"
fi

# Step 4: Inject profile
echo ""
echo "--- Step 4: Inject build profile ---"

if [[ -n "$PROFILE" ]]; then
    PROFILE_FILE="$OVERLAY_DIR/profiles/${PROFILE}.env"
    if [[ ! -f "$PROFILE_FILE" ]]; then
        echo "ERROR: Profile not found: $PROFILE_FILE"
        echo "Available profiles:"
        ls "$OVERLAY_DIR/profiles/"*.env 2>/dev/null | sed 's/.*\//  /' | sed 's/\.env$//' || echo "  (none)"
        exit 1
    fi
    cp "$PROFILE_FILE" "$WORKTREE/.build-profile.env"
    echo "  Profile injected: $PROFILE"
else
    echo "  No profile specified (use --profile to set one)"
fi

# Step 5: Record resolved revisions
echo ""
echo "--- Step 5: Record source revisions ---"

OVERLAY_REV="$(git -C "$PROJECT_ROOT" rev-parse HEAD 2>/dev/null || echo 'unknown')"

cat > "$WORKTREE/.build-metadata.json" <<META
{
  "prepared_at": "$(date -Iseconds)",
  "armbian_commit": "$ARMBIAN_COMMIT",
  "overlay_revision": "$OVERLAY_REV",
  "profile": "${PROFILE:-none}",
  "prepared_by": "prepare-armbian-worktree.sh",
  "host": "$(hostname)"
}
META
echo "  Build metadata written to .build-metadata.json"

echo ""
echo "=== Worktree Ready ==="
echo "  Path:    $WORKTREE"
echo "  Armbian: $ARMBIAN_COMMIT"
echo "  Overlay: $OVERLAY_REV"
echo "  Profile: ${PROFILE:-none}"
