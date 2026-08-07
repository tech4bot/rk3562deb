# Project Context — Samwise Armbian Platform

## What This Is

A repeatable, source-controlled, recovery-safe cross-compilation and image-build environment for the RK3562 tablet known as `samwise` (Doogee U10-class).

The platform uses the Armbian Build Framework as an upstream build dependency. All tablet-specific behavior lives in a separately versioned overlay layer in this repository.

## Target Hardware

| Attribute | Value |
|-----------|-------|
| Hostname | samwise |
| SoC | Rockchip RK3562 (4x Cortex-A53 @ 2.0 GHz) |
| Board identity | RK3562 RK817 TABLET LP4 Board |
| Product | Doogee U10-class tablet |
| Architecture | ARM64 / aarch64 |
| Display | 800x1280 DSI panel, portrait rotation required |
| Touch | GSL3673-class, 10-point multitouch |
| PMIC | Rockchip RK817 |
| Wi-Fi | Seekwave EA6621Q |
| NPU | 1x Rockchip NPU core (RKNN/RKLLM) |
| Sensor | DA223 / SC7A20 / Mir3DA accelerometer |
| Root filesystem | microSD ext4 (mmcblk0p4) |
| Boot partition | microSD FAT (mmcblk0p3), ~256 MiB |
| Internal storage | mmcblk2, ~116.5 GiB (UNTOUCHED) |
| Reference kernel | 6.1.118 #2 |

## Build Host

- **Name:** Conrad
- **Platform:** WSL2 Ubuntu 24.04 on x86_64
- **Build mode:** Containerized Armbian build (default)
- **Source location:** Linux filesystem under $HOME (not /mnt/c/)

## Engineering Context

This is a **tablet board-support package**, not a generic SoC build. The existing 6.1.118 system is the known-good reference. Any kernel that boots but loses DSI, touch, charging, Wi-Fi, sensor, or NPU support is a regression.

The present installation was reverse-engineered without vendor BSP or documentation, using Firefly RK3562 open-source repos as a starting point. The Armbian integration adds reproducibility, manifest tracking, and a formal upgrade path.

## Key Decisions

See `docs/DECISIONS.md` for the full log. Key initial decisions:

1. Armbian Build Framework is the upstream build engine, pinned by commit SHA.
2. eMMC writes are forbidden in all initial phases.
3. Compatibility-first approach: preserve 6.1 kernel behavior before attempting upgrades.
4. microSD-only images until boot chain is fully understood and documented.
5. Two-track strategy: Track A (compatibility preservation) before Track B (upstream convergence).
