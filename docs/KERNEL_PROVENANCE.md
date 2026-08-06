# Kernel Provenance — Samwise

**Status:** Written 2026-08-05 from the 2026-07-27 reconciliation plus direct
verification of the trees on Conrad. Supersedes the Phase-1 stub. One fact the
stub demanded is still unrecovered: the exact source commit of the running
kernel build.

## Known-Good Kernel (running on samwise)

```
Version:    6.1.118
Source:     github.com/rockchip-linux/kernel, branch develop-6.1
            (established from rk3562deb build.sh:16-17)
Defconfig:  rockchip_linux_defconfig, as replaced by
            overlay/arch/arm64/configs/rockchip_linux_defconfig
DTB:        rk3562-rk817-tablet-v10.dtb
Image:      uncompressed Image on the VFAT boot partition (extlinux on SD;
            direct U-Boot on eMMC — see D006/D007)
Commit:     UNRECOVERED — the develop-6.1 SHA the running build was made from
            was never recorded
```

**Open discrepancy — which build is running.** The 2026-07-27 TASKS
reconciliation records the running kernel as `#131`, built 2026-04-12, with
`#2` as its predecessor. But `~/rk_tablet/notes/samwise-target-facts.txt` (a
direct `uname -a` capture) and the original stub both record
`6.1.118 #2 SMP Thu Jun 4 21:24:25 PDT 2026` — a *later* build date than
`#131`'s. These cannot both describe the current state. Resolve with one
`uname -a` on samwise the next time it is reachable, and correct this file.
The old and current module trees compared byte-identical, so the practical
risk of the ambiguity is low.

**Not stock vendor.** The known-good kernel is `develop-6.1` plus the
rk3562deb overlay:

- `overlay/arch/` replaces several DTS/DTSI files (panel gpio4 wiring, wifi
  `sv6160` + `seekwcn_boot` node, camera dtsi);
- `overlay/kernel-patches/` carries the rk817 poweroff and boot-OCV patches;
- `overlay/arch/arm64/configs/rockchip_linux_defconfig` is a wholesale
  replacement of the stock defconfig (Seekwave symbols, Mali Bifrost instead
  of Midgard/Utgard, GSL3673 800x1280 touch variant, DA228E g-sensor,
  `CONFIG_EXTRA_FIRMWARE` linking the three Seekwave blobs, USB wifi dongle
  drivers, syscon poweroff);
- the Seekwave EA6621Q driver tree (`drivers/net/wireless/ea6621q`, 99 files
  + firmware blobs) exists in no upstream tree and is carried in
  `overlay/`.

## Candidate Kernels

### B-1 (current candidate) — Armbian build, vendor tree

The active candidate per **D012** (Armbian remains a full board port, built
from the Rockchip vendor kernel) and **D013** (Armbian's config is the base,
vendor symbols forced explicitly).

```
Repository:  https://github.com/rockchip-linux/kernel.git
Branch:      develop-6.1
Commit:      floating — cached clone on Conrad is at b4ef083dc (2025-07-12);
             not yet pinned. Pin after the first successful build.
Config:      Armbian config/kernel/linux-rk35xx-vendor.config base
             + D013 five-symbol hook (board config, ArmbianBuild 37cb49b45)
             + Seekwave symbol hook (doogee-u10-seekwave-wifi extension)
Patches:     userpatches/kernel/rk3562-doogee-u10/ in ArmbianBuild:
               fix-rk3562-tablet-panel-doogee-u10.patch   (gpio4 panel wiring, D011)
               fix-rk3562-tablet-wifi-doogee-u10.patch    (sv6160 + seekwcn_boot DT)
               enable-rknpu-rk3562-rk817-tablet.patch     (NPU node enable)
Extra src:   Seekwave driver vendored at build time via
             kernel_copy_extra_sources (never as a diff patch)
Build host:  Conrad (WSL2), Armbian build framework, fork
             GeospatialDaryl/build @ 37cb49b45
Status:      NEVER BUILT — staged 2026-07-27, no compile attempted since.
             All three patches verified to apply cleanly to the pristine
             cached tree on 2026-08-05.
```

Deliberately **not** ported into B-1 yet: RK817 battery/charging delta,
rk817-dev-off-poweroff, cameras (s5k5e8, s5k4h5yb), residual overlay
DTS/DTSI deltas — see TASKS.md Phase 4b.

### Superseded — Armbian rk35xx fork (the built images)

All images produced to date (2026-07-04 build; `-sdboot` and `-panelfix`
post-processed variants) carry `armbian/linux-rockchip rk-6.1-rkr3`,
kernel 6.1.75. Retired by D012 because it lacks the U10's entire
out-of-tree enablement set (no wifi driver at all, no RK817 battery delta,
no cameras). Useful only as boot-chain/panel evidence; do not extend.

### Future labels (from the original plan, all unstarted)

| Label | Meaning |
|-------|---------|
| update-6.1 | Later maintained 6.1-compatible candidate |
| lts-6.6 / lts-6.12 | Experimental newer LTS bring-up |

## Vendor Modifications the Tablet Depends On

| Modification | Form | Ported to B-1? |
|---|---|---|
| DSI panel gpio4 wiring | DTS delta (reference board ships gpio0) | ✅ patch, compile-verified vs known-good DTB |
| Seekwave EA6621Q wifi | out-of-tree driver + firmware + DT + config | ✅ vendored via extension |
| RKNPU node enable | DTS delta (driver 0.9.8 already in vendor tree) | ✅ patch |
| GSL3673 touch (800x1280 variant) | in-tree driver, config choice | ⚠️ present in Armbian base but `=m`, proven defconfig has `=y` |
| RK817 battery/charging | driver patches + mfd delta + boot-OCV patch | ❌ not ported |
| rk817-dev-off poweroff | patch | ❌ not ported |
| Mali GPU (Bifrost, `rk` platform) | in-tree vendor driver, config choice | ⚠️ `MALI_BIFROST=y` matches, but Armbian base *also* carries `MALI_MIDGARD=y` and `DRM_PANFROST=m`, both of which the proven defconfig removes/disables |
| MPP / RGA / VPU media | in-tree vendor drivers + D013 symbols | ✅ D013 hook (OSAL, CMA heap) |
| DA223/DA228E accelerometer | in-tree vendor driver, config choice | ⚠️ present in Armbian base but `=m` (with `GSENSOR_DEVICE`/`SENSOR_DEVICE` also `=m`), proven defconfig has all three `=y` |
| Camera sensors (s5k5e8, s5k4h5yb) | config + camera dtsi | ❌ deferred until base image boots |

**The ⚠️ rows are divergence in kind, not absence** (verified against
`config/kernel/linux-rk35xx-vendor.config`, 2026-08-05). Every one of these
symbols *is* in Armbian's base — D013's "102 vendor-only symbols" measurement
holds. What differs is `=m` where the proven system has `=y`, plus two extra
GPU drivers Armbian carries that the proven defconfig deliberately removes.

Two consequences for the first B-1 build:

- **GPU driver contention is the real risk.** Armbian's base has
  `MALI_BIFROST=y`, `MALI_MIDGARD=y` and `DRM_PANFROST=m` simultaneously.
  The proven defconfig sets `# CONFIG_DRM_PANFROST is not set` and drops
  Midgard/Utgard entirely, leaving Bifrost alone. If panfrost binds the Mali
  node first, the vendor Bifrost stack gets nothing. Check `dmesg` for both
  drivers probing before concluding the GPU works.
- **`=m` vs `=y` for touch and g-sensor** is probably benign (modules load
  from rootfs, nothing here is needed pre-pivot-root) but it is a real
  difference from the known-good system, so it belongs in the first-boot
  comparison rather than being assumed equivalent.

Neither is forced by a hook today. If the build confirms the panfrost
conflict, the fix is a third `custom_kernel_config` entry, not a defconfig
swap — that would contradict D013.

## Provenance Record Template

Unchanged from the original spec — every promoted candidate records:

```
Kernel:
  repository / branch / commit / tag
  config_hash: SHA-256 of .config
  patches: list with rationale
  build_host, compiler, build_date
```

The first B-1 build should produce the first filled-in record.
