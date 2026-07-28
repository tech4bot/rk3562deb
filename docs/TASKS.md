# Task Tracker — Samwise Armbian Platform

> **Reconciled 2026-07-27.** This file had drifted since 2026-06-18 and badly
> understated progress — it showed all of Phase 2 unstarted while four Armbian
> images had been built, the SD boot chain fixed, and the DSI panel brought up.
> Every box below was checked against the tree, not from memory; items with no
> evidence on disk are left unchecked even where they were probably done.
> Phases 3–6 are new: the July work had no place in the tracker at all.

## Phase 0 — Project and Recovery Foundation

- [x] Repository structure created
- [x] AGENTS.md written
- [x] PROJECT_CONTEXT.md written
- [x] ARCHITECTURE.md written
- [x] DECISIONS.md initialized — now carries D001–D009
- [x] RECOVERY_PLAYBOOK.md written
- [x] HARDWARE_TEST_MATRIX.md initialized
- [x] host-preflight.sh implemented — `scripts/host-preflight.sh`, plus `tests/host/test_preflight.py`
- [x] capture-samwise-baseline.sh implemented
- [x] flash-image-safely.sh with eMMC protection
- [x] verify-artifact.sh implemented
- [x] compare-baselines.py implemented
- [x] Build profiles created (minimal, hardware-test, tablet-dev)
- [x] CMake toolchain file created
- [x] .gitignore updated
- [ ] Run host-preflight.sh on Conrad — verify pass
      *(no recorded run; the script and its unit test exist, but no output is
      committed. Probably done informally — left unchecked for lack of evidence.)*
- [x] Run capture-samwise-baseline.sh against known-good system — `baseline/current-system/`
- [x] Verify known-good card image checksum — 2026-07-25 golden backup, sha256
      `a924d954…41d4`, verified independently on Samwise and on Conrad
- [x] Commit baseline data — 57 tracked files under `baseline/`, incl. `baseline/checksums/baseline.sha256`

## Phase 1 — Boot-Chain and Device-Tree Discovery

- [x] Capture baseline from live system (54 files + 231 DT compatible strings)
- [x] Capture raw FDT binary (155,648 bytes, SHA-256: 4f4f90a7...)
- [x] Document boot configuration mechanism (extlinux on SD, direct U-Boot on eMMC)
- [x] Identify actual DTB filename: `rk3562-rk817-tablet-v10.dtb`
- [x] Document kernel image format: uncompressed `Image` on VFAT boot partition
- [x] Identify U-Boot: Firefly `rk356x/firefly-5.10`, FIT image at 8 MiB offset
- [x] Record compatible strings: `rockchip,rk3562-rk817-tablet` / `rockchip,rk3562`
- [x] Write BOOT_CHAIN_DISCOVERY.md (Phase 1 complete)
- [x] Key finding: live system boots from eMMC, not SD card (D006 recorded)
- [x] Decision: Armbian board definition strategy — `config/boards/doogee-u10.wip`
      in the ArmbianBuild fork (`BOOTCONFIG=none`, `KERNEL_TARGET=vendor`,
      `SRC_EXTLINUX=yes`, GPT + FAT bootfs, SD boot chain via extension)
- [ ] Write KERNEL_PROVENANCE.md — still the original stub. Much of it is now
      known and just needs writing down:
  - source `github.com/rockchip-linux/kernel`, branch `develop-6.1` (`build.sh:16-17`)
  - defconfig `rockchip_linux_defconfig`, DTB `rk3562-rk817-tablet-v10.dtb`
  - running kernel 6.1.118 `#131`, built 2026-04-12; predecessor was `#2`
  - old and current module trees compared byte-identical
  - **not** stock upstream: `overlay/arch/` replaces several DTS/DTSI files and
    `overlay/kernel-patches/` carries rk817 poweroff and boot-OCV patches
  - the exact commit SHA of the `#131` build is still unrecovered

## Phase 2 — Pinned Armbian Build Skeleton

> **Deviation from plan.** Phase 2 assumed Armbian would live under
> `platform/armbian/` in this repo as a submodule or pinned clone. In practice a
> separate fork was used — `~/repos/ArmbianBuild` → `GeospatialDaryl/build`,
> branches `main` and `samwise-doogee-u10`. `platform/armbian/{source-lock,
> profiles,patches,userpatches/*}` and `manifests/{images,packages,sdk}` remain
> empty scaffolding. Either adopt the fork as the official location and delete
> the scaffolding, or wire the fork in as a submodule. Undecided — worth a
> D010 entry either way.

- [x] Initialize armbian-build as a pinned clone — done as a separate fork, see above
- [ ] Create initial source lockfiles — `platform/armbian/source-lock/` is empty
- [ ] Test prepare-armbian-worktree.sh — script exists, no recorded run
- [x] Run first Armbian build — went straight to tablet-specific rather than generic;
      four images built 2026-07-04 / 07-14 (CLI and XFCE desktop, each with an
      `-sdboot` variant)
- [ ] Verify manifest generation — `manifests/` is empty. Armbian emits its own
      `.img.txt` per image, but this repo's manifest step never ran
- [ ] Verify clean-worktree rebuild reproducibility

## Phase 3 — SD Boot Chain Enablement

- [x] Diagnose why the tablet ignored the SD card — sector 64 held the
      `rk3562_spl_loader` USB/maskrom container, not a BootROM idblock; BootROM
      found no "RKNS" signature and fell back to eMMC Android (2026-07-18)
- [x] Fix `build.sh` to pack `idblock.bin` from `make.sh --idblock` — `588f712`
- [x] Patch the already-built `-sdboot` images in place
- [x] Armbian extension writing idblock@64 + u-boot.itb@16384 into every future
      image, with magic-byte checks that fail the build — `268a14c`
- [x] Verify on hardware — BootROM now reads the SD; pulling the card drops the
      tablet to Android recovery
- [ ] Record the boot-chain fix in DECISIONS.md (no D-entry yet)

## Phase 4 — Display Bring-Up

- [x] Diagnose the Armbian black screen — DSI panel wired to gpio0 RK_PB0/RK_PC4
      (Rockchip reference board) instead of the U10's gpio4 RK_PB6/RK_PB5
- [x] Corroborate against independent sources — factory Android DTB, running
      6.1.118 DTB, and `rk3562deb/overlay/` all agree on gpio4
- [x] Establish that upstream does **not** carry the fix — both
      `rockchip-linux/kernel develop-6.1` and `armbian/linux-rockchip
      rk-6.1-rkr3` ship the reference wiring
- [x] Stopgap: extension installing the known-good DTB — ArmbianBuild `1ef5c10`
- [x] Boot-test on hardware — panel lights up, Armbian boots (2026-07-27)
- [x] Durable fix: DTS patch in `userpatches/kernel/rk35xx-vendor-6.1/` — `a6de456`
- [x] Verify the patch without a full build — `dtc -@` on the unpatched DTS
      reproduces the shipped DTB byte for byte; patched DTS yields a display
      subtree semantically identical to the known-good DTB
- [ ] Boot-test the DTS patch itself — the image that lit the panel carried the
      blob swap, not the patch. Next full rebuild is its first hardware test;
      `git revert a6de456` is the fallback
- [ ] Record the panel fix in DECISIONS.md (no D-entry yet)

## Phase 5 — First Boot and Hardware Validation

- [x] Build the hardware validation kit — `tests/hardware/session-001/`
      (`capture-matrix.sh`, `run-remote.sh`, `graft-bootloader.sh`)
- [x] Diagnose the Armbian first-boot stall — `armbian-firstlogin` blocking on
      `console=ttyS0` with nothing attached, behind a Plymouth splash; and the
      `tty1` check at `armbian-firstlogin:674` that makes `PRESET_*` preseeding
      silently no-op
- [ ] Inject the first-boot bypass into the image — **blocked** on credentials in
      `~/samwise-preseed.env` (delete `.not_logged_in_yet`, pre-place root
      `authorized_keys`, NetworkManager wifi keyfile, `console=tty1`, drop `splash`)
- [ ] Reach a login on the Armbian image
- [ ] Run `capture-matrix.sh` and record results — **all 20 matrix rows are still
      `—`**, including rows that demonstrably pass today. `tests/hardware/session-001/evidence/`
      contains only `.gitkeep`
- [ ] Fix the row 14 methodology gap (targets `/tmp`, a tmpfs — see the
      HARDWARE_TEST_MATRIX footnote, flagged 2026-07-12, still uncorrected)

## Phase 6 — NPU and Edge-AI Enablement

- [x] Package librknnrt 2.3.2 for RK3562 — `c925c27`
- [x] RKNN conversion workflow and NPU smoke-test kit — `0dbd65c`
- [x] RKNPU driver 0.9.8 backport + enable patch — `userpatches/kernel/rk35xx-vendor-6.1/`
- [x] RKLLM runtime working; Qwen3 0.6B loads and generates
- [x] Identify the invalid FP ASR model — `wav2vec2-5s-fp.rknn` is truncated
      (125,378,560 bytes on disk vs 194,469,888 declared)
- [ ] Establish a CPU reference ASR pipeline before any further conversion
- [ ] Diagnose the W8A8 all-blank CTC output (100% blank frames)
- [ ] Improve hybrid-model transcription quality (81–92% blank, poor decode)
- [ ] Repair the transcription service — remove the stale
      `mnt-sd\x2dbackup.mount` dependency; keep disabled until inference is useful

## Cross-Cutting / Unfinished

- [ ] Complete the rescue card — SSH key never installed into the rescue root
      (`/dev/mmcblk0p4`); see overview doc section 7.1
- [ ] Decide the `platform/armbian` vs separate-fork question (D010)
- [ ] Clean up credential-bearing artifacts once Armbian is up:
      `C:\Users\vandy\samwise-armbian-panelfix.img` and `~/samwise-preseed.env`

## Reference

Detailed narrative, risk register and acceptance criteria live in
`docs/Samwise_Senior_AI_Architect_Overview.md`. Phase 3–6 deliverables in the
original spec are sections 15.3–15.6.
