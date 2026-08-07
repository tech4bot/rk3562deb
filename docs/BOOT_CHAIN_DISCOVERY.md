# Boot Chain Discovery — Samwise

**Status:** Phase 1 complete (2026-06-18)
**Evidence source:** Baseline capture from live system at 192.168.11.167

## Critical Finding: Current System Boots from eMMC

The spec assumed the known-good system runs from microSD (`mmcblk0p4`). **This is incorrect.** The live system is booted from the internal eMMC:

- Root: `mmcblk2p25` (110.4 GiB ext4) mounted at `/`
- Root identified by: `PARTUUID=86190000-0000-4d2d-8000-7ad7000056e0`
- `/boot/` directory: **empty** — kernel and DTB are not in a filesystem-mounted `/boot`
- No `extlinux.conf` on the running system

The SD card (`mmcblk0`, 29.8 GiB) is inserted but not used as root. It has the partition layout of a previously-flashed SD-boot image (idbloader + uboot + boot VFAT + rootfs ext4) but the Boot ROM selected eMMC this time.

**Implication:** The SD card boot path for candidate images is proven by the existing `rk3562deb` build system (README confirms: insert SD card → Debian boots, remove → Android/eMMC boots), but the current live capture reflects the eMMC-resident Debian installation, not an SD-booted one.

---

## Resolved Boot Chain

### eMMC boot path (currently active)

```
RK3562 Boot ROM (mask ROM)
  → idbloader on eMMC (SPL/TPL)
      ddr-v1.06-cea47a5df0, spl-v1.06
  → U-Boot on eMMC (FIT image, mmcblk2p2 area)
      bl31-v1.22, bl32-v1.08
      Source: Firefly rk356x/firefly-5.10 branch
  → Kernel + DTB loaded from eMMC boot partition (raw, not filesystem)
      No extlinux.conf; U-Boot passes bootargs directly
  → Kernel: 6.1.118 #2 (aarch64, SMP)
  → Initramfs: not used
  → DTB: rk3562-rk817-tablet-v10 (loaded by U-Boot, name inferred from build system)
  → Root: PARTUUID=86190000-... → mmcblk2p25 (ext4)
```

### SD card boot path (project target)

```
RK3562 Boot ROM (mask ROM)
  → idbloader.img on SD card at offset 32 KiB (mmcblk0p1 area)
  → u-boot.itb on SD card at offset 8 MiB (mmcblk0p2 area)
  → extlinux.conf on boot VFAT partition (mmcblk0p3, 256 MiB at offset 16 MiB)
  → Kernel: /Image on boot partition
  → DTB: /rk3562.dtb on boot partition
  → Initramfs: not used
  → Root: PARTUUID=c0ffee11-2233-4455-6677-8899aabbccdd → mmcblk0p4 (ext4, 29.5 GiB)
```

Boot ROM priority: SD card > eMMC (when SD card has valid idbloader signature at sector 64).

---

## Boot Firmware Versions

From kernel cmdline `androidboot.fwver`:

| Component | Version |
|-----------|---------|
| DDR init | v1.06 (commit cea47a5df0) |
| SPL | v1.06 |
| BL31 (ARM Trusted Firmware) | v1.22 |
| BL32 (OP-TEE) | v1.08 |
| U-Boot | Firefly `rk356x/firefly-5.10` branch |

OP-TEE is confirmed present in DT: `/firmware/optee` with compatible `linaro,optee-tz`.
SCMI firmware also present: `/firmware/scmi` with compatible `arm,scmi-smc`.

---

## Device Tree Identity

| Property | Value |
|----------|-------|
| Model | `Rockchip RK3562 RK817 TABLET LP4 Board` |
| Compatible | `rockchip,rk3562-rk817-tablet` `rockchip,rk3562` |
| DTS filename (build system) | `rk3562-rk817-tablet-v10.dtb` |
| Panfrost variant | `rk3562-rk817-tablet-v10-panfrost.dtb` |
| Total DT nodes with compatible | 231 |

---

## Key Hardware DT Bindings

### Display

| Node | Compatible | Notes |
|------|-----------|-------|
| `dsi@ffb10000` | `rockchip,rk3562-mipi-dsi` | DSI controller, status=okay |
| `dsi@ffb10000/panel@0` | `aoly,sl008pa21y1285-b00` `simple-panel-dsi` | 4-lane DSI, rotation=90 |
| `vop@ff400000` | (VOP display controller) | Display output processor |
| `backlight` | (PWM backlight) | Brightness control |
| `display-subsystem` | (DRM aggregate) | Display pipeline |

Panel properties: 800x1280 native, 4 DSI lanes, rotation=90 degrees, init sequence in DT.

### Touch and Input

| Node | Compatible | Notes |
|------|-----------|-------|
| `i2c@ffa10000/...` | `GSL,GSL3673_800X1280` | Touchscreen (10-point) |
| `i2c@ffa10000/...` | `gs_sc7a20` | Accelerometer (SC7A20/DA223 compatible) |
| `i2c@ffa10000/...` | `gs_da223` | Accelerometer (alternate compatible) |
| `adc-keys` | (ADC key input) | Volume/ADC buttons |

### PMIC and Power

| Node | Compatible | Notes |
|------|-----------|-------|
| (i2c@ffa10000 bus) | RK817 PMIC | Battery, charger, regulators, codec |
| `vcc-sys` | (fixed regulator) | Main system power |
| `vcc-sd` | (regulator) | SD card power |
| `vdd-gpu` | (regulator) | GPU power domain |
| `vdd-npu` | (regulator) | NPU power domain |

### Wireless

| Node | Compatible | Notes |
|------|-----------|-------|
| `wireless-wlan` | `wlan-platdata` | WLAN platform data |
| `seekwcn_boot` | `seekwave,sv6160` | Seekwave Wi-Fi/BT chip |
| `wireless-bluetooth` | (BT node) | Bluetooth subsystem |
| `sdio-pwrseq` | (SDIO power sequence) | Wi-Fi power sequencing |

### GPU / NPU / Media

| Node | Compatible | Notes |
|------|-----------|-------|
| `gpu@ff320000` | `arm,mali-bifrost` | Mali Bifrost GPU |
| `npu@ff300000` | `rockchip,rk3562-rknpu` | NPU (1 core) |
| `rga@ff440000` | `rockchip,rga2_core0` | 2D graphics accelerator |
| `rkvdec@ff340100` | (video decoder) | Hardware video decode |
| `rkvenc@ff360000` | (video encoder) | Hardware video encode |
| `mpp-srv` | (media process platform) | MPP service |
| `isp@ff3f0000` | (ISP) | Camera image signal processor |

### Cameras

| Node | Compatible | Notes |
|------|-----------|-------|
| `i2c@ffa30000/s5k5e8@10` | `samsung,s5k5e8` | Front camera |
| `i2c@ffa30000/s5k4h5yb@36` | `samsung,s5k4h5yb` | Rear camera |
| `i2c@ffa30000/gc5035@37` | `galaxycore,gc5035` | Alternate sensor |
| `i2c@ffa30000/ov5648@35` | `ovti,ov5648` | Alternate sensor |
| `i2c@ffa30000/ov8858@36` | `ovti,ov8858` | Alternate sensor |
| `i2c@ffa30000/fp5510@c` | `fitipower,fp5510` | Lens actuator |
| `i2c@ffa30000/dw9714@c` | `dongwoon,dw9714` | Lens actuator |
| `i2c@ffa30000/cn3927v@c` | `chipnext,cn3927v` | Lens actuator |

Multiple camera sensor definitions exist in the DT; active sensors are `s5k5e8` (front) and `s5k4h5yb` (rear).

### Storage

| Node | Compatible | Notes |
|------|-----------|-------|
| `mmc@ff870000` | `rockchip,rk3562-dwcmshc` | eMMC controller (mmcblk2) |
| `mmc@ff880000` | `rockchip,rk3562-dw-mshc` | SD card controller (mmcblk0) |
| `mmc@ff890000` | `rockchip,rk3562-dw-mshc` | SDIO (Wi-Fi) |

---

## SD Card Image Layout (from existing build system)

```
Offset    Partition    Contents
32 KiB    idbloader    idbloader.img (SPL/TPL)
8 MiB     uboot        u-boot.itb (FIT image)
16 MiB    boot         256 MiB FAT: Image, rk3562.dtb, extlinux/extlinux.conf
272 MiB   rootfs       ext4 root filesystem
```

GPT partition table. Root identified by `PARTUUID=c0ffee11-2233-4455-6677-8899aabbccdd`.

---

## eMMC Partition Layout (observed, read-only)

25 partitions on `mmcblk2` (116.5 GiB). Android-oriented layout with:
- Multiple small partitions (4M–64M) for bootloader, trust, misc, etc.
- `mmcblk2p24` — 5 GiB (likely Android system)
- `mmcblk2p25` — 110.4 GiB ext4 (currently mounted as Debian root)

**Policy: DO NOT MODIFY.**

---

## Kernel Cmdline (eMMC boot, as captured)

```
earlycon=uart8250,mmio32,0xff210000
console=ttyS0,1500000n8
quiet splash loglevel=0
systemd.show_status=false rd.systemd.show_status=false
udev.log_priority=0
plymouth.ignore-serial-consoles
vt.global_cursor_default=0
video=DSI-1:800x1280@60,rotate=90
rw
root=PARTUUID=86190000-0000-4d2d-8000-7ad7000056e0
rootfstype=ext4
rootwait
```

Notable: serial console at ttyS0/1500000, DSI-1 display with rotation, PARTUUID root.

---

## Extlinux Boot Config (SD card path)

```
default linux
timeout 30
menu title RK3562 Boot

label linux
  kernel /Image
  fdt /rk3562.dtb
  append earlycon=uart8250,mmio32,0xff210000 console=ttyS0,1500000n8 quiet splash ...
         root=PARTUUID=c0ffee11-2233-4455-6677-8899aabbccdd rootfstype=ext4 rootwait
```

Four labels defined: `linux`, `linux-debug`, `linux-fallback` (panfrost DTB), `linux-fallback-debug`.

---

## Open Questions

1. **FDT blob capture:** `/sys/firmware/fdt` is root-read-only (0400). Need root access to capture binary DTB for exact comparison. The sysfs tree provides all node data but not the compiled blob for hashing.

2. **Armbian board definition:** The compatible string `rockchip,rk3562-rk817-tablet` is unlikely to exist in upstream Armbian. A local board definition will almost certainly be required. The closest Armbian family is `rockchip64` or `rk35xx`, but this needs validation against the pinned Armbian source.

3. **Boot ROM SD priority:** Boot ROM should prefer SD over eMMC. Current eMMC boot may mean the SD card idbloader is absent or the SD card was inserted after power-on.

---

## Decision Required

**D006: Board definition strategy** — Pending

Options:
- A) Create a new local Armbian board definition `samwise` referencing `rockchip,rk3562-rk817-tablet`
- B) Extend an existing Rockchip board definition with the samwise DTS/overlay
- C) Use the existing `rk3562deb` build system directly (no Armbian family mapping needed for Track A)

This depends on what board definitions exist in the pinned Armbian checkout. Must be validated in Phase 2.
