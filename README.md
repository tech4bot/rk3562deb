# rkdebian — Debian 13 for Doogee U10 (RK3562)

![Doogee U10 tablet running debian 13](docs/Doogee_U10_debian.jpeg)

## Download Pre-release Image

> **Current public build (pre-release, May 14, 2026):**
> - Release page: [tech4bot/rk3562deb prerelease-24052026](https://github.com/tech4bot/rk3562deb/releases/tag/prerelease-24052026)
> - Direct image download: [rk3562-debian.img.xz](https://github.com/tech4bot/rk3562deb/releases/download/prerelease-24052026/rk3562-debian.img.xz)
> - Video demo: [YouTube](https://youtu.be/DbX13_mahKc?si=Ba9u2xqAmoXM7nYb)

> **Run full Debian 13 Trixie on your Doogee U10 tablet — no bootloader unlock required.**
> Boot from SD card, remove it to return to stock Android. No changes to internal storage.

> **Reverse engineered from scratch** — no BSP, no vendor documentation, no official support.
> Built with the help of **Claude**, **Codex**, and **Antigravity** (Google Gemini), using **[Firefly RK3562](https://github.com/Firefly-rk-linux)** open-source repositories as a starting point.

---

## Overview

**rkdebian** is a build system that produces a complete, bootable Debian 13 Trixie image for the **Doogee U10** Android tablet, powered by the **Rockchip RK3562** SoC.

The resulting image is written to an SD card. Insert it and power on — the tablet boots Debian. Remove the SD card and it boots Android from internal eMMC as normal.

---

## Hardware: Doogee U10

| Component | Details |
|-----------|---------|
| SoC | Rockchip RK3562 (4× Cortex-A53 @ 2.0 GHz) |
| NPU | 1× Rockchip NPU core (active for RKLLM inference) |
| RAM | 4 GB LPDDR4 |
| Storage | 128 GB eMMC (Android) + SD card (Debian) |
| Display | 10.1" DSI panel, 1280×800 |
| PMIC | RK817 |

---

## What Works

| Feature | Status |
|---------|--------|
| **Display / Panel** | ✅ Full |
| **Touchscreen** | ✅ Full (gsl3673, 10-point multitouch) |
| **Wi-Fi** | ✅ Full (Seekwave EA6621Q) |
| **Bluetooth** | ✅ Full |
| **Speaker / Audio output** | ✅ Full |
| **Microphone** | ✅ Full |
| **3D Acceleration** | ⚠️ Partial (default image uses `mali` vendor stack; `panfrost` is an optional build profile) |
| **NPU (RKLLM / rknn-llm)** | ✅ Active (RK3562 supports one NPU core, `num_npu_core=1`) |
| **Accelerometer** | ✅ Full (SC7A20 / DA223) |
| **Flashlight (rear LED)** | ✅ Full (native Phosh top-menu torch toggle + brightness control via `rk-flashlightctl`) |
| **Power button behavior** | ✅ Full (short press sleeps on release, long press >=3s opens shutdown dialog) |
| **Lockscreen orientation memory** | ✅ Full (lock screen keeps last tablet orientation, including landscape) |
| **Cameras** | ⚠️ Partial (front `s5k5e8` + rear `s5k4h5yb` pipelines functional; color tuning still needs calibration) |
| **Battery / Charging** | ✅ Full (RK817 PMIC) |
| **SD card boot** | ✅ Full |
| **USB OTG** | ✅ Full |

> **Note:** the public pre-release image linked above is built with `RKDEBIAN_GPU_STACK=mali` unless explicitly stated otherwise.

## Default Installed Apps

| App | Notes |
|-----|-------|
| **Firefox ESR** | Preinstalled web browser |
| **Chromium** | Preinstalled web browser (installed when available on mirror) |
| **FreeTube** | Installed via Flatpak from Flathub by default (disable with `RKDEBIAN_PREINSTALL_FREETUBE=0` for smaller images) |
| **Drawing** | Touch-friendly paint app (installed when available on mirror) |
| **Snapshot** | Camera app (installed when available on mirror) |
| **Dolphin** | File manager |
| **Plasma Discover** | App store / software center |
| **Okular** | Document/PDF viewer |
| **Gedit** | Text editor |
| **Pavucontrol** | Audio controls |
| **Terminal** | `kgx` preferred, `gnome-terminal` fallback |
| **Flatpak + Flathub** | Enabled by default for app installs |

## NPU LLM (RK3562)

This tablet image supports local LLM inference on the RK3562 NPU using Rockchip's RKLLM stack.

### NPU software used

- [airockchip/rknn-llm](https://github.com/airockchip/rknn-llm) — runtime, RKLLM toolkit, demo app (`llm_demo`)
- [airockchip/rknn-toolkit2](https://github.com/airockchip/rknn-toolkit2) — RKNN conversion/toolchain dependency used by RKLLM workflows

### Model conversion setup used

- Target platform: `rk3562`
- Quantization: `W8A8`
- NPU cores: `num_npu_core=1` (RK3562 supports one NPU core)
- Optimization level: `0` (chosen for compatibility/stability on this board)

Example conversion command (host PC):

```bash
python3 convert_qwen_rk3562.py \
  --model-dir ./models/Qwen3-0.6B \
  --target-platform rk3562 \
  --quantized-dtype W8A8 \
  --optimization-level 0 \
  --num-npu-core 1 \
  --output ./out/Qwen3-0.6B_W8A8_RK3562_opt0.rkllm
```

### Benchmark (on tablet, NPU path)

Measured on **April 6, 2026** on `<tablet-ip>` with:
- prompt: `Output exactly 300 English words about arithmetic speed testing do not include punctuation and do not stop early`
- `MAX_NEW_TOKENS=64`, `MAX_CONTEXT_LEN=1024`
- runner: `~/npu-test/xcompile/demo_Linux_aarch64/run_llm_rk3562.sh`

Commands used:

```bash
# Qwen3-0.6B (first run includes fix_freq)
USE_FIX_FREQ=1 RKLLM_LOG_LEVEL=1 PROMPT="Output exactly 300 English words about arithmetic speed testing do not include punctuation and do not stop early" \
  ./run_llm_rk3562.sh ~/npu-test/models/Qwen3-0.6B_W8A8_RK3562_opt0.rkllm 64 1024

# Qwen2.5-1.5B
USE_FIX_FREQ=0 RKLLM_LOG_LEVEL=1 PROMPT="Output exactly 300 English words about arithmetic speed testing do not include punctuation and do not stop early" \
  ./run_llm_rk3562.sh ~/npu-test/models/Qwen2.5-1.5B-Instruct_W8A8_RK3562.rkllm 64 1024
```

Warm-run average (runs 2-3):

| Model | Init Time (ms) | Prefill (tok/s) | Generate (tok/s) |
|-------|-----------------|-----------------|------------------|
| `Qwen3-0.6B_W8A8_RK3562_opt0` | `1788.70` | `57.62` | `4.92` |
| `Qwen2.5-1.5B-Instruct_W8A8_RK3562` | `4800.76` | `42.78` | `2.18` |

Result: `Qwen3-0.6B` is significantly faster on this RK3562 tablet for local NPU inference.

---

## Known Issues

- Battery may report `0%` after the tablet has been powered off for a couple of hours.
- `rk-battery-gauge-fix.service` fixes this on boot.
- If the tablet did not fully power off, reboot once; on the next boot the battery level should be corrected.
- Front (`s5k5e8`) and rear (`s5k4h5yb`) camera preview/capture are functional, but colors are still slightly off and require additional ISP calibration.

---

## Requirements

**Host machine:** x86-64 Linux (Debian/Ubuntu recommended)

Install all build dependencies with:

```bash
sudo apt-get install \
  git make gcc-aarch64-linux-gnu \
  bc bison flex device-tree-compiler \
  genimage wget tar mtools \
  xz-utils \
  debootstrap qemu-user-static \
  e2fsprogs
```

---

## Building

### Full build (recommended)

Builds U-Boot, kernel, Debian rootfs, and produces a ready-to-flash SD card image:

```bash
./build.sh all
```

With full logging to file (`tee`) while preserving the real build exit status:

```bash
set -o pipefail
./build.sh all 2>&1 | tee build.log
```

`./build.sh` with no target defaults to `all`.

The final image is written to:
- `out/rk3562-debian.img.xz` — compressed final image (recommended)
- `output/update/update.img.xz` — compressed Firefly-compatible path

Compatibility/raw images are also kept:
- `out/rk3562-debian.img`
- `output/update/update.img`

---

### CLI usage and options

```bash
./build.sh [options] {check|lunch|uboot|extboot|updateimg|updatepkg|compile|rootfs|image|all}
```

| Option | Values | Description |
|--------|--------|-------------|
| `--ui-session` | `phosh` | Session profile to bake into the image |
| `--gpu-stack` | `mali`, `panfrost` | Select userspace/kernel graphics stack |
| `--display-server` | `auto`, `wayland`, `x11` | Desktop backend preference passed into rootfs build |
| `--cpu-governor` | e.g. `performance`, `schedutil` | Baseline governor used by power-tuning services |
| `--force-clean-rootfs` | flag | Force full rootfs rebuild (same effect as `RKDEBIAN_FORCE_CLEAN_ROOTFS=1`) |
| `--no-force-clean-rootfs` | flag | Explicitly disable forced rootfs cleanup |
| `-h`, `--help` | flag | Show usage |

---

### Individual build targets

| Command | What it does |
|---------|-------------|
| `./build.sh check` | Verify all build dependencies are installed |
| `./build.sh lunch` | Select a build configuration (defconfig) |
| `./build.sh uboot` | Build U-Boot only |
| `./build.sh extboot` | Build the Linux kernel only |
| `./build.sh rootfs` | Build the Debian 13 rootfs only, then verify the requested build profile marker |
| `./build.sh compile` | Build U-Boot + kernel (skip rootfs and image) |
| `./build.sh image` | Assemble the final SD card image from existing artifacts (with rootfs profile verification) |
| `./build.sh updateimg` | Legacy image assembly path (SDK-compat); packages image without running profile verification |
| `./build.sh updatepkg` | Create an offline update tarball (`output/update/update.tar.gz`) from `out/rootfs` + `out/boot/*` |
| `./build.sh all` | Full end-to-end build (default) |

`image` and `updatepkg` require existing build artifacts (`out/rootfs`, kernel/DTB, and boot config files).

---

## Environment Variables

These variables can be set before running `build.sh` to control build behaviour:

### Rootfs

| Variable | Default | Description |
|----------|---------|-------------|
| `RKDEBIAN_FORCE_CLEAN_ROOTFS` | `0` | Set to `1` to wipe and fully rebuild the Debian rootfs from scratch. Useful when switching between different image profiles so stale packages do not carry over. |
| `ROOTFS_IMAGE_SIZE` | `auto` | Override the rootfs partition size (e.g. `4G`, `3584M`). By default the size is calculated automatically from actual rootfs usage plus headroom. |
| `ROOTFS_HEADROOM_MB` | `512` | Free space headroom added on top of actual rootfs usage when using `auto` sizing. |
| `ROOTFS_MIN_MB` | `2560` | Minimum rootfs image size in MiB when using `auto` sizing. |
| `RKDEBIAN_DISPLAY_SERVER` | `wayland` | Session backend preference for desktop stack selection (`wayland`, `x11`, or `auto`). Phosh images use Wayland by default. |
| `RKDEBIAN_UI_SESSION` | `phosh` | UI session to auto-login in LightDM. Current supported value: `phosh`. |
| `RKDEBIAN_GPU_STACK` | `mali` | GPU stack to build for: `mali` (vendor userspace) or `panfrost` (Mesa/Panfrost, no `libmali`). |
| `RKDEBIAN_CPU_GOVERNOR` | `performance` | Baseline CPU governor used at boot and as the default mapping for Phosh `balanced` mode. |
| `RKDEBIAN_MALI_GBM_PROVIDER` | `vendor` | Mali-only option: `vendor` keeps `mali/libgbm.so.1` from the blob package (default), `debian` overrides it to Debian `libgbm.so.1` for compatibility testing. |
| `RKDEBIAN_PREINSTALL_FREETUBE` | `1` | Set to `0` to skip FreeTube preinstall and significantly reduce image size. |
| `RKDEBIAN_MINIMIZE_IMAGE` | `0` | Set to `1` for aggressive size reduction (prunes non-English locales plus `/usr/share/doc`, `/usr/share/help`, `/usr/share/man`, `/usr/share/info`, and unused Flatpak objects). |

### Kernel

| Variable | Default | Description |
|----------|---------|-------------|
| `RKDEBIAN_MAKE_THREADS` | `auto` | Override kernel build parallelism. By default it uses a memory-safe value (`min(nproc, RAM_GiB/2)`) to reduce random `cc1`/`drivers` build failures on low-RAM hosts. |
| `RKDEBIAN_KEEP_OVERLAY_PMIC_PATCHES` | `0` | Set to `1` to use the overlay PMIC drivers (`rk808.c`, `rk817_battery.c`, `rk817_charger.c`) instead of the upstream kernel versions. |

### Examples

```bash
# Force a clean rootfs rebuild
RKDEBIAN_FORCE_CLEAN_ROOTFS=1 ./build.sh all

# Same using CLI flags
./build.sh all --force-clean-rootfs

# Force clean rootfs rebuild with a fixed 4 GB rootfs partition
RKDEBIAN_FORCE_CLEAN_ROOTFS=1 ROOTFS_IMAGE_SIZE=4G ./build.sh all

# Build only the rootfs, force clean
RKDEBIAN_FORCE_CLEAN_ROOTFS=1 ./build.sh rootfs

# Rebuild image only (U-Boot and kernel already built)
./build.sh image

# Build kernel only
./build.sh extboot

# Keep overlay PMIC patches during kernel build
RKDEBIAN_KEEP_OVERLAY_PMIC_PATCHES=1 ./build.sh extboot

# Force a Wayland desktop image for testing
./build.sh all --display-server=wayland

# Explicitly disable force-clean (useful in scripted runs)
./build.sh all --no-force-clean-rootfs

# Override baseline governor used for Phosh balanced mode mapping
RKDEBIAN_CPU_GOVERNOR=schedutil ./build.sh all

# Show CLI usage and target list
./build.sh --help

# Build a Phosh image on Mesa/Panfrost (optional profile, clean rootfs strongly advised)
./build.sh all --ui-session=phosh --gpu-stack=panfrost --force-clean-rootfs

# Mali stack with Debian libgbm override (only for compatibility testing)
RKDEBIAN_MALI_GBM_PROVIDER=debian ./build.sh all --ui-session=phosh --gpu-stack=mali --force-clean-rootfs

# Size-focused build for easier GitHub uploads
RKDEBIAN_FORCE_CLEAN_ROOTFS=1 RKDEBIAN_MINIMIZE_IMAGE=1 RKDEBIAN_PREINSTALL_FREETUBE=0 ./build.sh all

# Size-focused build while keeping default FreeTube preinstall enabled
RKDEBIAN_FORCE_CLEAN_ROOTFS=1 RKDEBIAN_MINIMIZE_IMAGE=1 RKDEBIAN_PREINSTALL_FREETUBE=1 ./build.sh all
```

When changing `RKDEBIAN_UI_SESSION` or `RKDEBIAN_GPU_STACK`, use `--force-clean-rootfs` to avoid stale package carry-over.

### Phosh Power Mode Mapping

Images include `rk-power-profile-sync.service`, which maps Phosh power modes
(`power-profiles-daemon`) to cpufreq policy on-device:

- `balanced` -> governor from `RKDEBIAN_CPU_GOVERNOR` (default `performance`), max freq cap `100%`
- `power-saver` -> governor `powersave`, max freq cap `65%`
- `performance` (if exposed by hardware) -> governor `performance`, max freq cap `100%`

Tune mapping on-device in `/etc/default/rk-power-profile-map`.

### Phosh UX Integrations

- Rear camera flashlight is exposed as LED `camera:flash`, so Phosh shows the native top-menu torch icon.
- `rk-flashlightctl` supports both toggle and intensity control (`set 0..100`) for the rear LED.
- `rk-powerkey-longpress.service` owns hardware power-key policy:
  - short press (`<3s`) -> suspend on key release
  - long press (`>=3s`) -> standard GNOME shutdown dialog
  - logind/GNOME press-triggered defaults are disabled to avoid immediate sleep on key-down
- Lockscreen orientation is preserved from the last active tablet orientation, so wake/lock does not force portrait when the tablet was in landscape.

### Safe Phosh Session Testing (on-device)

Images include `rk-session-failsafe.timer`, which checks 5 minutes after boot if a risky session test is still armed.

```bash
# Arm rollback before rebooting into a risky session test
sudo install -d /var/lib/rk-session-failsafe
sudo touch /var/lib/rk-session-failsafe/armed
sudo reboot
```

Behavior:
- If Phosh is healthy, watchdog auto-disarms and does nothing.
- If session bring-up fails, watchdog restores LightDM + Phosh autologin and reboots.

---

## OTA Updates (on-device)

Once the tablet is running Debian, you can apply updates without reflashing the SD card.

**Build an update package on your host:**

```bash
./build.sh all        # or just ./build.sh image && ./build.sh updatepkg
```

This produces `output/update/update.tar.gz`.

**Copy it to the tablet** (via USB, SSH, or any file manager) and drop it in one of these inbox directories:

| Path | Notes |
|------|-------|
| `/home/chaos/update/` | Primary drop location |
| `/update/pending/` | Alternative drop location |

On the **next reboot**, the `rk-apply-update` service automatically detects the newest `*.tar.gz` or `*.tgz` package, applies rootfs + boot payloads, then reboots to finalize. Legacy compatibility path `/update/update.tar.gz` is also checked.

Package archive behavior:
- Successfully applied packages are moved to `/update/applied/`
- Invalid/extract-failed packages are moved to `/update/failed/`
- Already-applied packages (same SHA-256) are moved to `/update/duplicate/`

Update progress and errors are logged to `/var/log/rk-update.log`.

> If a package fails to apply (corrupt archive, wrong layout) it is moved to `/update/failed/` and the system boots normally.

---

## Flashing to SD Card

After a successful build, flash the compressed image to your SD card:

```bash
# Replace /dev/sdX with your SD card device (check with lsblk)
xz -dc out/rk3562-debian.img.xz | sudo dd of=/dev/sdX bs=4M status=progress conv=fsync
```

> **Warning:** Double-check the device path. Writing to the wrong device will overwrite your data.

Insert the SD card into the Doogee U10 and power it on. Debian will boot automatically.
Remove the SD card to return to Android.

---

## Default Credentials

The build system creates the following accounts in the Debian image:

| Account | Username | Password | Notes |
|---------|----------|----------|-------|
| Standard user | `chaos` | `chaos` | Passwordless sudo |
| Root | `root` | `root` | Direct root login |

> **Change these on first boot:**
> ```bash
> passwd                   # change chaos password
> sudo passwd root         # change root password
> ```

---

## Image Layout

The SD card image uses a GPT partition table:

| Partition | Offset | Size | Contents |
|-----------|--------|------|----------|
| `idbloader` | 32 KiB | — | SPL / first-stage bootloader |
| `uboot` | 8 MiB | — | U-Boot FIT image |
| `boot` | 16 MiB | 256 MiB | FAT: kernel Image, DTB, extlinux.conf |
| `rootfs` | 272 MiB | auto | ext4: Debian 13 Trixie root filesystem |

The rootfs partition is automatically expanded to fill the SD card on first boot.

---

## Source Tree

```
rkdebian/
├── build.sh              # Main build entry point
├── build_rootfs.sh       # Debian rootfs builder (debootstrap + chroot)
├── genimage.cfg          # SD card image partition layout
├── extlinux.conf         # Bootloader config (kernel + DTB)
├── splash.png            # Boot splash screen
├── overlay/              # Custom kernel drivers, DTS, firmware, services, and headers
│   ├── arch/             # Device tree sources (DTS/DTSI)
│   ├── drivers/          # Out-of-tree kernel drivers (Wi-Fi EA6621Q, cameras, PMIC)
│   ├── firmware/         # Wi-Fi firmware blobs (Seekwave EA6621Q)
│   ├── include/          # Build-time kernel header overrides
│   ├── kernel-patches/   # Kernel patches applied during build
│   ├── etc/              # On-device config overrides (logind, etc.)
│   ├── mali-shim.c       # Mali GPU userspace shim (compiled during build)
│   └── *.sh / *.service  # On-device setup scripts and systemd units
├── debs/                 # Pre-built .deb packages (Mali GPU, Rockchip MPP)
├── mali/                 # Mali GPU userspace library (.so)
├── wifi/                 # Wi-Fi firmware, vendor SDK, and porting guides
├── tools/                # On-device camera capture and ISP diagnostic tools
├── docs/                 # Design specs and build notes
├── src/                  # Cloned sources (kernel, u-boot, rkbin) — populated by build
├── out/                  # Build artifacts (kernel, rootfs, images)
└── output/update/        # Final flashable image + OTA update package
```

---

## Kernel & Bootloader Versions

| Component | Version / Branch |
|-----------|-----------------|
| Linux kernel | 6.1.x (`develop-6.1`, rockchip-linux) |
| U-Boot | Firefly `rk356x/firefly-5.10` |
| rkbin | Rockchip upstream `master` |
| Debian | 13 Trixie (arm64) |

---

## Attribution

Third-party components included in this repository:

### Mali GPU binaries

The prebuilt Mali GPU packages in `debs/` and the userspace library in `mali/` are sourced from:

- [christianhaitian/rk3566_core_builds](https://github.com/christianhaitian/rk3566_core_builds/tree/master/mali/aarch64)
- [tsukumijima/libmali-rockchip](https://github.com/tsukumijima/libmali-rockchip/releases)

These binaries are provided by those projects under their respective terms. ARM Mali firmware and userspace libraries are proprietary ARM IP.

### Rockchip MPP (Media Process Platform)

The Rockchip MPP packages in `debs/` (`librockchip-mpp1`, `librockchip-mpp-dev`, `librockchip-vpu0`) are sourced from:

- [rockchip-linux/mpp](https://github.com/rockchip-linux/mpp)

Rockchip MPP is licensed under the Apache 2.0 License.

### Seekwave Wi-Fi / Bluetooth

The Wi-Fi and Bluetooth driver source in `overlay/drivers/net/wireless/ea6621q/` and firmware blobs in `overlay/firmware/` and `wifi/` are provided by **Seekwave Technology Co. Ltd**. The driver is released by the vendor under the GNU General Public License v2.0 (GPL-2.0).

---

## License

**MIT License — © 2026 tech4bot**

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

The Linux kernel, U-Boot, Debian packages, Rockchip rkbin, and third-party drivers included in or produced by this build system retain their respective upstream licenses.
