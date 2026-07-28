# Decision Log — Samwise Armbian Platform

## Format

Each decision is numbered and includes: context, decision, rationale, and consequences.

---

## D001: Use Armbian Build Framework as upstream build engine

**Date:** 2026-06-18
**Status:** Accepted

**Context:** The project needs a reproducible image-build pipeline for an ARM64 tablet. The existing build.sh works but lacks manifest tracking, source pinning, and formal upgrade paths.

**Decision:** Adopt the Armbian Build Framework as the upstream build dependency, pinned by commit SHA. All tablet-specific work lives in a separately versioned overlay.

**Rationale:** Armbian provides kernel, bootloader, rootfs assembly, and containerized cross-build support. It is designed for this class of problem and supports WSL2/Ubuntu 24.04.

**Consequences:** Must learn Armbian's extension/userpatch conventions. Must validate all configuration against the pinned source, not internet examples.

---

## D002: eMMC writes forbidden in initial phases

**Date:** 2026-06-18
**Status:** Accepted

**Context:** The tablet's internal eMMC (~116.5 GiB) contains the vendor Android installation. Accidental writes could brick the device.

**Decision:** No scripted writes to /dev/mmcblk2 in any project script. All flash helpers reject eMMC targets with hard guards.

**Rationale:** The project's value is a safe, removable-media development platform. eMMC migration is a separate, later milestone.

**Consequences:** All images must boot from microSD. Flash scripts require explicit target identification with size/model guards.

---

## D003: Compatibility-first kernel strategy (Track A before Track B)

**Date:** 2026-06-18
**Status:** Accepted

**Context:** The known-good system runs a vendor-derived 6.1.118 kernel with custom display, touch, Wi-Fi, and NPU support. Generic newer kernels may lack these drivers.

**Decision:** First Armbian image preserves 6.1-based kernel behavior (Track A). Newer kernel candidates (Track B) are separate experiments that cannot overwrite Track A artifacts.

**Rationale:** A kernel that boots but loses tablet hardware support is a regression. Compatibility must be proven before modernization.

**Consequences:** Multiple kernel candidate profiles. Independent test reports per candidate. Track A remains reproducible even as Track B evolves.

---

## D004: microSD-only images until boot chain is documented

**Date:** 2026-06-18
**Status:** Accepted

**Context:** The boot mechanism (extlinux vs. U-Boot env vs. other) has not been formally documented from evidence.

**Decision:** All images target removable microSD only. Boot chain discovery (Phase 1) must complete before any bootloader installation decisions.

**Rationale:** Assumptions about boot mechanisms cause bricked devices. Evidence-based discovery prevents this.

**Consequences:** Phase 1 is a blocking gate for image promotion.

---

## D005: Containerized build as release-reference path

**Date:** 2026-06-18
**Status:** Accepted

**Context:** Build reproducibility depends on consistent toolchain and dependency versions.

**Decision:** Containerized Armbian build on Conrad WSL2 Ubuntu 24.04 is the default and release-reference build mode.

**Rationale:** Isolates host package drift, gives reproducible dependency boundary, aligns with Armbian's supported model.

**Consequences:** Docker must be available on the build host. Native builds are a developer convenience, not the release path.

---

## D006: Known-good system runs from eMMC, not SD card

**Date:** 2026-06-18
**Status:** Observed (corrects spec assumption)

**Context:** The spec (Section 2.1) states "Root filesystem: microSD ext4 root currently mounted from `/dev/mmcblk0p4`". Baseline capture on 2026-06-18 shows the live system is actually rooted on **eMMC** (`mmcblk2p25`, 110.4 GiB ext4, mounted at `/`).

**Observed evidence:**
- `lsblk` shows only `mmcblk2p25` has a mountpoint (`/`)
- `cmdline` shows `root=PARTUUID=86190000-0000-4d2d-8000-7ad7000056e0` (eMMC)
- `/boot/` is empty — no kernel or DTB in a filesystem
- SD card (`mmcblk0`) is present with 4 partitions but nothing mounted

**Decision:** Acknowledge that the "known-good system" being captured is the eMMC-resident Debian installation. The SD card boot path is proven by the existing `rk3562deb` build system but was not active during this capture. The eMMC baseline is still valid evidence for device-tree, hardware state, and driver behavior.

**Consequences:**
- SD card boot path for candidate images must be established independently (using the existing build system's extlinux.conf approach, which is proven to work)
- The eMMC protection policy remains unchanged — no writes to mmcblk2
- Future captures should document which boot path was active

---

## D007: Boot configuration method is extlinux (SD) / direct U-Boot (eMMC)

**Date:** 2026-06-18
**Status:** Accepted

**Context:** The spec warned not to assume extlinux. Discovery shows two distinct paths:
- **SD card boot:** Uses `extlinux.conf` on a VFAT boot partition (proven by existing build system)
- **eMMC boot:** U-Boot passes bootargs directly (no extlinux.conf, no `/boot` filesystem)

**Decision:** Candidate Armbian images targeting SD card will use extlinux.conf, matching the existing proven SD card boot path. This is compatible with Armbian's standard boot mechanism.

**Consequences:** Armbian's extlinux-based boot is aligned with the SD card path. No custom boot script needed for Track A.

---

## D008: NPU uses the vendor RKNPU stack; NPU enablement pins Track A to the vendor kernel

**Date:** 2026-07-04
**Status:** Accepted

**Context:** The stock system runs RKNN/RKLLM workloads on the RK3562's 1-TOPS NPU via the vendor `rknpu` kernel driver (0.9.7 in the pinned rk35xx-vendor-6.1 tree) plus Rockchip's `librknnrt` userspace. The mainline "rocket" DRM accel driver supports RK3588 only, with no announced RK3562 support; an out-of-tree DKMS module exists for RK356x but is unproven. Audit of the first built image (2026-06-20, vendor 6.1.75) found `rk3562.dtsi` leaves the NPU and its IOMMU `status = "disabled"` and `rk3562-rk817-tablet-v10.dts` never enables them, while the stock DTB (baseline `device-tree/fdt.dts`) runs the NPU enabled with `rknpu-supply` on the `vdd_npu` PWM regulator.

**Decision:** Track A uses the vendor RKNPU stack exclusively: in-tree `rknpu` driver, DT nodes enabled via userpatch `enable-rknpu-rk3562-rk817-tablet.patch` (mirrors stock/EVB wiring: `&rknpu` okay + `rknpu-supply = <&vdd_npu>`, `&rknpu_mmu` okay), and `librknnrt`/RKLLM packaged as opt-in, separately versioned userland. CPU inference (XNNPACK/onnxruntime) is a correctness reference only; GPU (Mali-G52) inference is out of scope.

**Rationale:** The vendor stack is the only production-viable NPU path for RK3562 and is already proven on this exact tablet. `librknnrt` enforces a minimum kernel-driver version, so driver and runtime versions must be recorded together (baseline capture now collects both).

**Consequences:** NPU support anchors samwise to the vendor 6.1 kernel; any Track B (newer kernel) candidate is expected to lose NPU functionality until mainline gains RK3562 support, and must record that gap explicitly. Stock driver/runtime versions must be captured from the device before reflashing (`/sys/kernel/debug/rknpu/version`, `librknnrt.so` version string) to confirm the ≤ 0.9.7 compatibility assumption.

**Update (2026-07-04):** Provenance captured from the stock device: RKNPU driver **v0.9.8**, librknnrt **2.3.2** (2025-04-09). The pinned tree's 0.9.7 driver is below RKLLM's documented ≥ 0.9.8 minimum, so upstream commit `736d89f34415` ("driver: rknpu: Update rknpu driver, version: 0.9.8", rk-6.1-rkr4.1) is backported as userpatch `rknpu-driver-0.9.8-backport.patch` alongside the DT enable patch. The pristine commit applies cleanly to the rkr3 tree; the intermediate rk3576 devfreq change was deliberately excluded (depends on `rockchip_opp_set_low_length`, absent from the pinned tree).

**Update (2026-07-05):** The ≥ 0.9.8 driver contract is now empirically confirmed, not just documented. `librkllmrt` **1.3.0** (RKLLM SDK, RK3562-supported since release-v1.2.0) was packaged as `debs/librkllmrt_1.3.0-2_arm64.deb` (runtime `.so` + `rkllm.h` pinned to the same upstream tag — mixing versions across a re-package is an ABI hazard; `llm_demo` built from upstream source, since no prebuilt Linux binary is shipped upstream). Running the packaged `llm_demo` on the stock eMMC system (still driver 0.9.8) printed `rkllm-runtime version: 1.3.0, rknpu driver version: 0.9.8, platform: RK3562` with no driver-too-low warning, and a converted Qwen3-0.6B model (w4a16_g64, `scripts/convert-rkllm-model.sh`) produced a correct answer end-to-end through `librkllmrt` + the vendor driver — the first LLM inference run on this project's NPU stack. This is stock-system precedent only; hardware test matrix row 18 still requires the same run on a flashed candidate image. (A literal `"0.9.7"` string is also present in `librkllmrt.so` near the version-warning format strings; the actual check substitutes runtime `%d.%d.%d` values, so the documented ≥ 0.9.8 floor stands, not 0.9.7.)

Packaging lesson (toolchain ABI): the first packaging attempt (`librkllmrt_1.3.0-1`, superseded and deleted) cross-compiled `llm_demo` with Conrad's native Ubuntu 24.04 sysroot, which leaked `GLIBC_2.38`/`GLIBCXX_3.4.32` symbol requirements into the binary — both above what Debian 12 Bookworm (the target OS) ships (2.36/3.4.30), so the binary failed to start on target with `version 'GLIBC_2.38' not found`. Root cause: GCC's cross-compiler bundles its own libstdc++ headers/library ahead of any `--sysroot`, and Ubuntu 24.04's `<stdlib.h>` substitutes `__isoc23_strtol` for plain `strtol()` at compile time. Fix (`-2`): cross-compile against a locally fetched Debian 12 Bookworm arm64 sysroot with explicit `-isystem`/`-nostdlib++` flags forcing the Bookworm libc/libstdc++ ahead of the toolchain's own. General rule for this project: any target-userland binary built on Conrad (not just RKLLM) must be linked against a Bookworm sysroot, not Conrad's native one — full root-cause writeup lives in the packaged deb's own `/usr/share/doc/librkllmrt/README.samwise`.

---

## D009: ggml/llama.cpp NPU backend evaluated and deferred for RK3562

**Date:** 2026-07-04
**Status:** Deferred (revisit if upstream changes; see Consequences)

**Context:** As a possible alternative or complement to the proprietary vendor RKLLM runtime (D008), the ggml/llama.cpp ecosystem's NPU backend work was evaluated as a research question: does a more standard, actively-maintained inference stack exist for this hardware? The live project in this space, `invisiofficial/rk-llama.cpp`, targets **RK3588 only** and builds on RKNPU's matmul acceleration for that chip. Rockchip's own `rknn_matmul_api.h` header (RKNN SDK 2.3.2) documents RK3562's matmul support as **int8 + fp16 only — no int4 matmul pipeline**. The mainline "rocket" DRM accel driver (tracked in wiki 06) is also RK3588-only as of 2026-07, with no announced RK3562 work.

**Decision:** Do not pursue a ggml/llama.cpp NPU backend for RK3562 at this time. RKLLM (D008) remains the sole LLM inference runtime for this platform.

**Rationale:** `rk-llama.cpp` has no RK3562 fork or support, so adopting it would mean a from-scratch port, not a drop-in. Even on its native RK3588 target, the project's own published numbers show *decode* throughput regressing versus plain CPU llama.cpp (25.8 to 20.2 tok/s), with only prefill improving (~2.8x) — a mixed result on the hardware it was designed for. RK3562 additionally lacks the int4 matmul pipeline the RK3588 int4 quant paths rely on, so even a port would need a different, unproven quantization strategy. RKLLM already gives RK3562 a working, vendor-supported w4a16 quantized path (D008 update, 2026-07-05, on-device confirmed), so switching runtimes for a regression on unsupported hardware is not justified.

**Consequences:** Track A's LLM serving path stays vendor-only (RKLLM), matching the RKNN vision-inference stance in D008. Revisit if: (a) `rk-llama.cpp` or a fork adds real RK3562 support, (b) its RK3588 decode regression is resolved, or (c) the mainline rocket driver gains RK3562 support (wiki 06 open item), any of which would change the cost/benefit of a from-scratch backend. No project code or packaging changes result from this decision; it is recorded to avoid re-litigating the same research question later.

## D010: SD-boot images carry a BootROM idblock, not the spl_loader container

**Date:** 2026-07-18 (recorded 2026-07-27)
**Status:** Implemented and hardware-verified

**Context:** The tablet ignored every SD image because sector 64 held `rk3562_spl_loader_*.bin` — a boot_merger "LDR " container intended for rkdeveloptool over maskrom USB. The BootROM found no "RKNS" idblock signature on SD and silently fell back to eMMC Android. Root cause was `build.sh` doing `cp rk3562_spl_loader_*.bin idbloader.img`.

**Decision:** The BootROM artifact is `idblock.bin` produced by vendor U-Boot `make.sh --idblock` (`mkimage -T rksd`, TPL ddr_1332MHz + SPL). `build.sh` packs it at sector 64 (rk3562deb `588f712`); the ArmbianBuild fork embeds the same chain (idblock @64, `u-boot.itb` @16384) into every image via the `doogee-u10-sdboot` extension with magic-byte checks that fail the build on bad blobs (ArmbianBuild `268a14c`).

**Rationale:** The two loader formats are visually similar files with entirely different consumers; only the rksd/"RKNS" form is BootROM-readable from SD.

**Consequences:** SD boot is proven on hardware — pulling the card drops the tablet to Android recovery, confirming the BootROM reads it. Any future image that fails to boot from SD should be checked at sector 64 *first* (`dd … skip=64 | head -c4` must read `RKNS`) before deeper diagnosis.

## D011: The Doogee U10 panel fix lives in the DTS, not in a swapped DTB

**Date:** 2026-07-27
**Status:** Implemented; blob variant hardware-verified, DTS patch compile-verified (first build pending)

**Context:** Armbian images black-screened with a healthy boot chain. The vendor DTS (`rk3562-rk817-tablet-v10.dts`) describes the Rockchip *reference* tablet — panel enable/reset on gpio0 RK_PB0/RK_PC4 — while the U10 wires them to gpio4 RK_PB6/RK_PB5, with a `vcc3v3_lcd_n` supply, `rotation = <90>`, `bus-format = <0x100a>`, and `dsi,flags = 0xc03`. Same board name, model string, and compatible; different hardware. Confirmed by three independent sources: the factory Android DTB, the running 6.1.118 DTB, and this repo's `overlay/` DTS. Neither `rockchip-linux/kernel develop-6.1` nor `armbian/linux-rockchip rk-6.1-rkr3` carries the correct wiring.

**Decision:** Fix at DTS source via a kernel patch in the ArmbianBuild fork (`a6de456`), sourced from this repo's `overlay/`. The blob-substitution extension that first proved the fix on hardware is retained in history (`1ef5c10`) as a revert target.

**Rationale:** A swapped DTB from a 6.1.118 build inside a differently-versioned image works but breaks silently on kernel bumps and destroys the symbolic/commented source form. The DTS patch was verified cheaply: `dtc -@` on the unpatched DTS reproduces the shipped DTB byte-for-byte (proving the toolchain faithful), and the patched DTS yields a display subtree semantically identical to the known-good DTB.

**Consequences:** The dtc-reproduction verification method is now the standard way to validate DT changes here without a build. The hardware boot that lit the panel used the blob swap; the DTS patch itself is exercised by the next full build.

## D012: Armbian remains a full board port, built from the Rockchip vendor kernel

**Date:** 2026-07-27
**Status:** Implemented (retarget committed; first build pending)

**Context:** After the panel fix, measurement showed the panel was a small fraction of the platform gap: Armbian's kernel has no driver for the U10's Seekwave SWT6621S wifi (101 files, in no upstream tree), no RK817 battery/charger support for this board, no U10 camera sensors — all maintained by this repo's `overlay/` as modifications on top of `rockchip-linux/kernel develop-6.1`. Options evaluated: (A) port everything onto Armbian's kernel fork; (B) Armbian userspace on the vendor kernel — found unsupported in practice, since `armbian-bsp-cli` hard-depends on an Armbian kernel package and no skip-build path exists; (C) drop Armbian. Chosen: A, then refined to "B-1" — A with the kernel base swapped to the vendor tree.

**Decision:** The doogee-u10 board builds its kernel from `rockchip-linux/kernel` branch `develop-6.1` — the exact tree this repo builds and the provenance of the known-good 6.1.118 kernel — via a board-scoped `post_family_config_branch_vendor` hook (same mechanism as thinkpad-x13s), with `KERNELPATCHDIR=rk3562-doogee-u10`. The rk35xx family default is untouched for other boards. (ArmbianBuild `a98b5408f`; wifi port in `b9e5404f8`.)

**Rationale:** Every U10 enablement delta is maintained against the vendor tree; porting across armbian's fork adds an unmeasured divergence for no benefit, since neither tree is upstream-maintained. Concrete wins from the retarget: the rknpu-0.9.8 backport patch became unnecessary (the vendor tree ships it — it reverse-applies), and the panel/wifi/rknpu-enable patches all apply to the pristine tree. Honest caveat, measured after the fact: the DTS divergence between the two trees was only 17 lines for this board, so the risk that motivated the swap was smaller than argued; the rknpu simplification and provenance alignment still justify it.

**Consequences:** Remaining port scope: RK817 battery/charging (+ boot-OCV and dev-off poweroff patches), cameras, and the residual DTS/DTSI deltas. D008's vendor-kernel pinning is reinforced. The first `./compile.sh` under the retarget is the real test of the entire stack — nothing after commit `268a14c` has been boot-tested except the blob-swap panel fix.

## D013: Kernel config baseline is Armbian's, with vendor symbols forced explicitly

**Date:** 2026-07-27
**Status:** Implemented (hook committed; first build pending)

**Context:** With the kernel retargeted (D012), which config drives it: Armbian's `linux-rk35xx-vendor.config` (4,759 enabled symbols, generated against armbian's fork) or this repo's proven `rockchip_linux_defconfig` (2,048 enabled after expansion against the vendor tree)? Measured symbol-set difference: 102 symbols enabled in the vendor defconfig are unknown to Armbian's config — of which nearly all are SPI-NOR/NAND flash vendors, other SoCs (RV1126B, RK3506), UFS, and build-only flags; the board-critical set (CPU_RK3562, CLK_RK3562, ROCKCHIP_RKNPU, DRM_ROCKCHIP, ROCKCHIP_DW_MIPI_DSI, Mali) is already present in Armbian's config. In the other direction, 1,307 symbols enabled in Armbian's config are unknown to the vendor defconfig — the general-purpose distro set (overlayfs, apparmor, audit, bridge/veth, containers, filesystems, USB classes).

**Decision:** Keep `linux-rk35xx-vendor.config` as the base. Force the handful of plausibly-relevant vendor-only symbols via a board-scoped `custom_kernel_config` hook: `DMABUF_HEAPS_ROCKCHIP_CMA_HEAP`, `ROCKCHIP_MPP_OSAL`, `ROCKCHIP_CLK_PVTPLL`, `CRYPTO_DEV_ROCKCHIP_CE`, `CRYPTO_DEV_ROCKCHIP_CRYPTO`. Camera ISP/VPSS variants wait until cameras are in scope; DSI2 stays off (this panel is dw-mipi-dsi).

**Rationale:** The asymmetry is 102-mostly-irrelevant vs 1,307-mostly-essential. Swapping to the vendor defconfig would silently strip the distro userspace support Armbian's rootfs assumes; `olddefconfig` reconciliation against the new tree is the smaller risk and Armbian warns loudly (`kernel_config_check_and_repair`) when it has to change anything.

**Consequences:** The five-symbol hook is the remaining pre-build change. Watch the first build's diffconfig warnings for symbols the new tree renames or drops.
