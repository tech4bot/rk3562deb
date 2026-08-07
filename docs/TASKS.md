# Task Tracker — Samwise Armbian Platform

> **Reconciled 2026-07-27.** This file had drifted since 2026-06-18 and badly
> understated progress — it showed all of Phase 2 unstarted while four Armbian
> images had been built, the SD boot chain fixed, and the DSI panel brought up.
> Every box below was checked against the tree, not from memory; items with no
> evidence on disk are left unchecked even where they were probably done.
> Phases 3–6 are new: the July work had no place in the tracker at all.

> **Status check 2026-08-05.** No state change since 2026-07-27 — the B-1
> retarget is staged but the first `./compile.sh` under it has still not run.
> Re-verified this date: all three `rk3562-doogee-u10` patches apply cleanly
> to the pristine vendor clone at `b4ef083dc`; both repos fully pushed.
> Snapshot: `docs/STATUS.md`.

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
- [x] Write KERNEL_PROVENANCE.md — written 2026-08-05 from the reconciled
      facts. Two open items tracked inside it: the exact commit SHA of the
      running build is unrecovered, and the running-build identity itself is
      contradicted (`#131` per this tracker vs `#2` per the direct uname
      capture in `~/rk_tablet/notes/samwise-target-facts.txt`) — one
      `uname -a` on samwise settles it

## Phase 2 — Pinned Armbian Build Skeleton

> **Deviation from plan.** Phase 2 assumed Armbian would live under
> `platform/armbian/` in this repo as a submodule or pinned clone. In practice a
> separate fork was used — `~/repos/ArmbianBuild` → `GeospatialDaryl/build`,
> branches `main` and `samwise-doogee-u10`. `platform/armbian/{source-lock,
> profiles,patches,userpatches/*}` and `manifests/{images,packages,sdk}` remain
> empty scaffolding. Either adopt the fork as the official location and delete
> the scaffolding, or wire the fork in as a submodule. Undecided — needs its
> own DECISIONS entry (D010–D013 are now taken by other decisions).

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
- [x] Record the boot-chain fix in DECISIONS.md — D010 (2026-07-27)

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
- [x] Record the panel fix in DECISIONS.md — D011 (2026-07-27)

## Phase 4b — Vendor-Kernel Retarget and Wifi Port (B-1, 2026-07-27)

> Strategy recorded in D012. After the panel fix, measurement showed Armbian's
> kernel was missing the U10's entire out-of-tree enablement set (wifi, battery,
> cameras — all maintained by this repo's `overlay/` against
> `rockchip-linux/kernel develop-6.1`). Rather than port across two vendor
> forks, the board now builds its kernel from the vendor tree itself.

- [x] Seekwave EA6621Q wifi ported — driver vendored (99 files + 2 headers +
      5 firmware blobs) via `kernel_copy_extra_sources`; Kconfig/Makefile merged
      line-by-line (never copied — rk3562deb's versions delete a dozen other
      wifi drivers); config symbols from the proven defconfig;
      `CONFIG_EXTRA_FIRMWARE` links blobs into the image (ArmbianBuild `b9e5404f8`)
- [x] Wifi DT patch — `wifi_chip_type` "ap6255"→"sv6160" + `seekwcn_boot` node;
      compile-verified against the known-good DTB
- [x] Kernel retargeted to `rockchip-linux/kernel develop-6.1` via board-scoped
      `post_family_config_branch_vendor` hook; `KERNELPATCHDIR=rk3562-doogee-u10`
      (ArmbianBuild `a98b5408f`)
- [x] Panel patch regenerated against the vendor tree (one anchor moved:
      NO_EOT_PACKET vs armbian's renamed EOT_PACKET); re-verified, dsi,flags=0xc03
- [x] rknpu-0.9.8 backport dropped — vendor tree already ships it (reverse-applies)
- [x] All three patches verified to apply in sequence to a pristine vendor clone
- [x] Kernel config decision — D013: Armbian's config stays the base;
      measurement: 102 vendor-only symbols (mostly irrelevant) vs 1,307
      armbian-only (distro-essential)
- [x] Apply the D013 five-symbol `custom_kernel_config` hook — ArmbianBuild
      `37cb49b45`; all five symbols verified present in the vendor tree's Kconfigs
- [ ] **First `./compile.sh` under the retarget** — the real test of everything
      since `268a14c`; watch diffconfig warnings for renamed/dropped symbols
- [ ] Port RK817 battery/charging — `rk817_charger.c`, `rk817_battery.c`,
      `rk808.c` mfd delta + `rk817-boot-ocv-calibration.patch`
- [ ] Port `rk817-dev-off-poweroff.patch`
- [ ] Cameras (s5k5e8, s5k4h5yb + camera dtsi) — deferred until base image boots
- [ ] Audit residual overlay DTS/DTSI deltas (evb1 dtsi 349 lines, camera dtsi
      264 lines, linux/android dtsi small) for anything else load-bearing

## Phase 5 — First Boot and Hardware Validation

- [x] Build the hardware validation kit — `tests/hardware/session-001/`
      (`capture-matrix.sh`, `run-remote.sh`, `graft-bootloader.sh`)
- [x] Diagnose the Armbian first-boot stall — `armbian-firstlogin` blocking on
      `console=ttyS0` with nothing attached, behind a Plymouth splash; and the
      `tty1` check at `armbian-firstlogin:674` that makes `PRESET_*` preseeding
      silently no-op
- [ ] Inject the first-boot bypass into the image — **blocked** on credentials in
      `~/samwise-preseed.env` (delete `.not_logged_in_yet`, pre-place root
      `authorized_keys`, NetworkManager wifi keyfile, `console=tty1`, drop `splash`).
      Target is now the **first B-1 image**, not the old panelfix image — that
      image has no wifi driver, so a wifi keyfile in it is inert
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
- [ ] Decide the `platform/armbian` vs separate-fork question (needs a DECISIONS entry)
- [ ] Clean up superseded/credential artifacts:
      `C:\Users\vandy\samwise-armbian-panelfix.img` (+ `.sha256`) is now
      **obsolete** — wrong kernel base, no wifi driver; delete once a B-1 image
      exists. `~/samwise-preseed.env` (still placeholder-only) holds credentials
      once filled — delete after injection
- [x] Push local commits to the forks — verified 2026-08-05: ArmbianBuild
      `main` == `fork/main` at GeospatialDaryl/build (`37cb49b45`);
      rk3562deb `main` == `origin/main` (`f9e6544`)

## Reference

Detailed narrative, risk register and acceptance criteria live in
`docs/Samwise_Senior_AI_Architect_Overview.md`. Phase 3–6 deliverables in the
original spec are sections 15.3–15.6.
