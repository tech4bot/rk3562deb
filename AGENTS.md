# AGENTS.md — Samwise Armbian Platform

## Project Identity

- **Project:** samwise-armbian-platform
- **Repository:** rk3562deb
- **Target device:** samwise (Doogee U10-class RK3562 tablet)
- **Target OS:** Debian Bookworm ARM64 via Armbian Build Framework
- **Build host:** Conrad (WSL2 Ubuntu 24.04 on x86_64)

## Key Principles

1. **Upstream stays clean.** `third_party/armbian-build` is pinned to a commit SHA and never modified. All tablet-specific work lives under `platform/armbian/`.
2. **Evidence before replacement.** No boot component is replaced based on filename or SoC family alone. The current live system is the reference.
3. **One variable per experiment.** Kernel, bootloader, DTB, rootfs, display stack, and NPU are separate change domains.
4. **Bootability first.** Reproducible build -> boot -> SSH -> storage/network -> display/touch -> sensors/power -> GPU/media/NPU -> desktop.
5. **Rollback is mandatory.** No candidate image ships without a tested recovery path.
6. **eMMC is off-limits.** No scripted writes to internal storage in initial phases. Scripts enforce this with hard guards.

## Repository Layout

```
rk3562deb/
  baseline/          - Captured evidence from the known-good system
  platform/armbian/  - Profiles, userpatches, patches, source locks
  scripts/           - Host-preflight, baseline capture, build wrappers, flash safety
  toolchains/        - CMake cross-compilation config, sysroot, pkg-config
  tests/             - Host-side, image, DTB, and hardware tests
  manifests/         - Build artifact manifests (images, packages, SDK)
  artifacts/         - Generated build outputs (gitignored)
  work/              - Disposable Armbian worktrees/caches (gitignored)
  third_party/       - Pinned upstream dependencies (armbian-build submodule)
  docs/              - Architecture, decisions, test matrices, recovery
```

## Build Modes

- **Platform image:** `./scripts/build-image.sh --profile samwise-minimal`
- **Kernel only:** `./scripts/build-kernel-only.sh --profile samwise-minimal`
- **SDK export:** `./scripts/export-sdk.sh --artifact <manifest.json>`
- **Host check:** `./scripts/host-preflight.sh`
- **Baseline capture:** `./scripts/capture-samwise-baseline.sh --host frodo@samwise`

## Safety Rules for AI Agents

- NEVER write to `/dev/mmcblk2` or any eMMC device.
- NEVER modify files in `third_party/armbian-build/`.
- NEVER flash an image without running `verify-artifact.sh` first.
- NEVER promote a candidate image without the hardware test matrix.
- NEVER commit secrets, Wi-Fi credentials, or SSH private keys.
- ALWAYS use project wrapper scripts, not raw Armbian commands.
- ALWAYS verify that build targets point to removable media only.
- ALWAYS record source commits, checksums, and manifests for artifacts.

## Phased Work

| Phase | Goal | Gate |
|-------|------|------|
| 0 | Project scaffold, safety scripts, baseline capture | Preflight passes, recovery verified |
| 1 | Boot-chain and device-tree discovery | Boot mechanism fully documented |
| 2 | Pinned Armbian build skeleton | Clean build completes, manifests valid |
| 3 | Compatibility boot image | Cold boot from candidate SD |
| 4 | Core hardware bring-up | Hardware test matrix passes |
| 5 | Developer image and SDK | Cross-compiled app runs on samwise |
| 6 | Controlled kernel evolution | Independent candidates, no regressions |
