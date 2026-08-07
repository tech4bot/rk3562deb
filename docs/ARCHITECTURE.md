# Architecture — Samwise Armbian Platform

## System Diagram

```
Armbian Build Framework (pinned upstream, read-only)
                +
samwise board-support overlay (platform/armbian/)
                +
known-good tablet evidence (baseline/)
                =
reproducible Samwise image artifacts (artifacts/)
```

## Build Flow

```
host-preflight.sh
  → prepare-armbian-worktree.sh --profile <name>
    → verify pinned checkout
    → create disposable worktree in work/
    → copy userpatches overlay
    → inject profile
  → build-image.sh --profile <name>
    → invoke Armbian compile.sh with profile parameters
    → collect artifacts
    → generate manifest + checksums
  → verify-artifact.sh --image <img> --manifest <json>
    → checksum, manifest fields, eMMC guard, lockfile check
  → flash-image-safely.sh --image <img> --target /dev/sdX
    → eMMC block, device identification, confirmation
  → collect-target-test-report.sh --host frodo@samwise
    → capture candidate state
    → compare against baseline
```

## Repository Layers

### Layer 1: Upstream (third_party/armbian-build)
- Pinned to exact commit SHA
- Never modified by project scripts
- Provides: compile.sh, kernel/u-boot build system, rootfs assembly

### Layer 2: Overlay (platform/armbian/)
- Profiles: build parameter sets for different image types
- Userpatches: board definitions, kernel config, device-tree, firmware
- Patches: kernel, u-boot, DTB patches with rationale
- Source locks: pinned commit SHAs for all upstream sources

### Layer 3: Evidence (baseline/)
- Captured from the known-good running system
- Device tree, boot config, kernel modules, hardware state
- Used as the regression reference

### Layer 4: Tooling (scripts/)
- Build wrappers, safety checks, verification, SDK export
- All operator-facing actions go through these scripts

## Boot Chain (Discovery Pending)

```
Boot ROM
  → idbloader (SPL/TPL)
  → U-Boot
  → extlinux.conf (likely, pending Phase 1 confirmation)
  → kernel Image
  → DTB
  → rootfs on microSD
```

The actual boot mechanism must be confirmed during Phase 1.

## Safety Architecture

1. **eMMC protection:** All flash/write scripts reject mmcblk2 targets
2. **Known-good preservation:** Baseline capture is read-only; known-good card never overwritten
3. **Upstream isolation:** Armbian checkout is read-only; all changes go through overlay
4. **Artifact verification:** Checksums and manifest validation before any flash
5. **Rollback:** Candidate images use separate microSD; known-good card retained
