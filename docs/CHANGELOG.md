# Changelog — Samwise Armbian Platform

## [Unreleased]

### Added
- Phase 0 project scaffold: directory structure, documentation, scripts
- AGENTS.md with project identity and safety rules
- Host preflight script (scripts/host-preflight.sh)
- Baseline capture script (scripts/capture-samwise-baseline.sh)
- Safe flash script with eMMC protection (scripts/flash-image-safely.sh)
- Armbian worktree preparation (scripts/prepare-armbian-worktree.sh)
- Image build wrapper (scripts/build-image.sh)
- Kernel-only build wrapper (scripts/build-kernel-only.sh)
- Artifact verification (scripts/verify-artifact.sh)
- SDK export (scripts/export-sdk.sh)
- Target test report collection (scripts/collect-target-test-report.sh)
- Baseline comparison tool (scripts/compare-baselines.py)
- Build profiles: samwise-minimal, samwise-hardware-test, samwise-tablet-dev
- CMake cross-compilation toolchain file
- Hardware test matrix (docs/HARDWARE_TEST_MATRIX.md)
- Recovery playbook (docs/RECOVERY_PLAYBOOK.md)
- Architecture and decisions documentation
- Four Armbian images for the U10 — CLI and XFCE desktop, kernel 6.1.75,
  each with an `-sdboot` variant (2026-07-04 / 07-18)
- Seekwave EA6621Q wifi port into the Armbian build (driver vendoring
  extension, DT patch, config symbols, firmware via CONFIG_EXTRA_FIRMWARE)
- Golden-backup verification and 2026-07-27 TASKS reconciliation
- KERNEL_PROVENANCE.md written from reconciled facts (2026-08-05)
- STATUS.md project snapshot (2026-08-05)

### Changed
- Kernel source for the Armbian board retargeted from armbian/linux-rockchip
  to rockchip-linux/kernel develop-6.1 (D012); Armbian config stays the base
  with vendor symbols forced explicitly (D013) — staged 2026-07-27, first
  build still pending

### Fixed
- SD boot chain: BootROM idblock (RKNS) written at sector 64 instead of the
  spl_loader container; tablet now boots Armbian from SD (D010, 2026-07-18)
- DSI panel black screen: gpio4 wiring corrected in the DTS, replacing the
  interim known-good-DTB swap (D011, 2026-07-27)
