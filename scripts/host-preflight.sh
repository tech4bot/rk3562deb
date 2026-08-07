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

pass() { printf "${GREEN}[PASS]${NC} %s\n" "$1"; }
fail() { printf "${RED}[FAIL]${NC} %s\n" "$1"; FAIL=$((FAIL + 1)); }
warn() { printf "${YELLOW}[WARN]${NC} %s\n" "$1"; WARN=$((WARN + 1)); }
info() { printf "       %s\n" "$1"; }

echo "=== Samwise Armbian Platform — Host Preflight Check ==="
echo "Host: $(hostname)"
echo "Date: $(date -Iseconds)"
echo ""

# Architecture
ARCH="$(uname -m)"
if [[ "$ARCH" == "x86_64" ]]; then
    pass "Architecture: $ARCH"
else
    warn "Architecture: $ARCH (x86_64 preferred for cross-compilation)"
fi

# OS / WSL2
if [[ -f /proc/version ]]; then
    PROC_VERSION="$(cat /proc/version)"
    if [[ "$PROC_VERSION" == *microsoft* || "$PROC_VERSION" == *WSL* ]]; then
        pass "WSL2 environment detected"
    else
        warn "Not running under WSL2 (build host spec is WSL2 Ubuntu 24.04)"
    fi
fi

if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    if [[ "${ID:-}" == "ubuntu" && "${VERSION_ID:-}" == "24.04" ]]; then
        pass "OS: Ubuntu 24.04"
    else
        warn "OS: ${PRETTY_NAME:-unknown} (spec requires Ubuntu 24.04)"
    fi
else
    fail "Cannot determine OS release"
fi

# RAM
if [[ -f /proc/meminfo ]]; then
    MEM_KB=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
    MEM_GB=$(( MEM_KB / 1024 / 1024 ))
    if (( MEM_GB >= 8 )); then
        pass "RAM: ${MEM_GB} GiB available (>= 8 GiB required)"
    else
        fail "RAM: ${MEM_GB} GiB available (8 GiB minimum required)"
        info "Increase WSL memory allocation in .wslconfig"
    fi
else
    warn "Cannot determine available RAM"
fi

# Disk space
if command -v df &>/dev/null; then
    FREE_KB=$(df --output=avail "$HOME" 2>/dev/null | tail -1 | tr -d ' ')
    FREE_GB=$(( FREE_KB / 1024 / 1024 ))
    if (( FREE_GB >= 60 )); then
        pass "Disk: ${FREE_GB} GiB free in \$HOME (>= 60 GiB required)"
    elif (( FREE_GB >= 30 )); then
        warn "Disk: ${FREE_GB} GiB free in \$HOME (60 GiB recommended, may work with less)"
    else
        fail "Disk: ${FREE_GB} GiB free in \$HOME (60 GiB minimum required)"
    fi
fi

# Source location check — must not be on /mnt/c or similar Windows mount
REAL_PROJECT="$(realpath "$PROJECT_ROOT")"
if [[ "$REAL_PROJECT" == /mnt/[a-z]/* ]]; then
    fail "Project is on a Windows-mounted filesystem ($REAL_PROJECT)"
    info "Move the project to a Linux-native path under \$HOME"
    info "Windows mounts break Linux permissions, symlinks, and build performance"
else
    pass "Project is on Linux filesystem: $REAL_PROJECT"
fi

# Git
if command -v git &>/dev/null; then
    GIT_VER="$(git --version 2>/dev/null | head -1)"
    pass "Git: $GIT_VER"
else
    fail "Git is not installed"
fi

# Docker / container runtime
CONTAINER_RT=""
if command -v docker &>/dev/null; then
    if docker info &>/dev/null 2>&1; then
        CONTAINER_RT="docker"
        DOCKER_VER="$(docker --version 2>/dev/null | head -1)"
        pass "Container runtime: $DOCKER_VER"
    else
        warn "Docker is installed but not accessible (check daemon / permissions)"
        info "Run: sudo usermod -aG docker \$USER && newgrp docker"
    fi
elif command -v podman &>/dev/null; then
    CONTAINER_RT="podman"
    PODMAN_VER="$(podman --version 2>/dev/null | head -1)"
    pass "Container runtime: $PODMAN_VER"
else
    warn "No container runtime found (Docker or Podman recommended for reproducible builds)"
    info "Native builds may work but are not the release-reference path"
fi

# Cross-compilation tools (informational; Armbian brings its own)
for tool in aarch64-linux-gnu-gcc make bc bison flex dtc; do
    if command -v "$tool" &>/dev/null; then
        pass "Tool available: $tool"
    else
        warn "Tool not found: $tool (Armbian containerized build provides its own)"
    fi
done

# Python (needed for compare-baselines.py and test infrastructure)
if command -v python3 &>/dev/null; then
    PY_VER="$(python3 --version 2>/dev/null)"
    pass "Python: $PY_VER"
else
    warn "python3 not found (needed for test/comparison scripts)"
fi

# ShellCheck (optional but spec-required for CI)
if command -v shellcheck &>/dev/null; then
    pass "ShellCheck: $(shellcheck --version 2>/dev/null | head -2 | tail -1)"
else
    warn "ShellCheck not found (required for script linting)"
fi

# Internet connectivity (for initial source bootstrap)
if ping -c1 -W3 github.com &>/dev/null 2>&1; then
    pass "Internet: github.com reachable"
else
    warn "Cannot reach github.com (needed for initial source bootstrap only)"
fi

# SSH client
if command -v ssh &>/dev/null; then
    pass "SSH client available"
else
    warn "SSH client not found (needed for target communication)"
fi

echo ""
echo "=== Summary ==="
if (( FAIL > 0 )); then
    printf "${RED}%d check(s) FAILED${NC}" "$FAIL"
    if (( WARN > 0 )); then
        printf ", ${YELLOW}%d warning(s)${NC}" "$WARN"
    fi
    echo ""
    echo "Fix FAIL items before attempting a build."
    exit 1
elif (( WARN > 0 )); then
    printf "${GREEN}All hard requirements passed${NC}, ${YELLOW}%d warning(s)${NC}\n" "$WARN"
    echo "Warnings are informational — build may proceed."
    exit 0
else
    printf "${GREEN}All checks passed.${NC}\n"
    exit 0
fi
