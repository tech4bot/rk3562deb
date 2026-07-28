# Samwise Recovery and Edge-AI Stabilization
## Senior AI Architect Overview

**System:** Doogee U10 / Rockchip RK3562 tablet
**Hostname:** `samwise`
**Primary user:** `frodo`
**Status date:** 2026-07-26
**Document purpose:** Senior-architecture record of the recovery process, identified problems, implemented solutions, current state, risks, and next steps.

> **Provenance note.** This document was authored in an external assistant session and
> transcribed into the repository on 2026-07-27. Claims marked **[verified on Conrad]**
> were independently re-checked against the local filesystem at transcription time.
> One factual correction was applied — see [Appendix A](#appendix-a--transcription-verification-log).

---

## 1. Executive Summary

Samwise is a Rockchip RK3562-based tablet running Debian from the device's internal eMMC while relying on a microSD card for the bootloader, Linux kernel, device tree, and recovery environment.

The recovery work has established a functioning two-path boot architecture:

```text
Normal path:
microSD bootloader and boot files
    -> Linux kernel and RK3562 device tree from microSD
        -> Debian root filesystem on internal eMMC

Rescue path:
microSD bootloader and boot files
    -> Linux kernel and RK3562 device tree from microSD
        -> independent Debian rescue root on microSD
```

The normal eMMC-root path is verified and operational. The rescue path has booted far enough to start networking and SSH, but final verification is pending because the rescue environment rejected the login with `Permission denied (publickey)`. The remaining recovery task is therefore not a kernel or bootloader problem. It is an access-control problem: Conrad's SSH public key must be installed into the rescue root's `chaos` account.

The core edge-AI hardware and runtime stack is working:

- RK3562 NPU device access is available.
- RKNN Lite runtime initializes successfully.
- RKLLM runtime initializes successfully.
- A Qwen3 0.6B RKLLM model loads and generates text.
- The internal microphone records valid audio.
- A hybrid Wav2Vec2 RKNN model executes and emits nonblank CTC tokens.
- A W8A8 Wav2Vec2 RKNN model executes but emits 100% blank CTC frames.
- The original floating-point RKNN model is invalid or truncated.
- The automatic audio-transcription service is disabled pending model and service repair.

The system is no longer in a general recovery crisis. It is now in a controlled stabilization phase centered on:

1. final rescue-root authentication and proof;
2. preservation of the golden and rescue SD cards;
3. removal of stale service dependencies;
4. ASR model validation and quantization analysis;
5. observability, artifact provenance, and reproducibility.

---

## 2. System Architecture

### 2.1 Hardware

| Component | Current understanding |
|---|---|
| Device | Doogee U10 tablet |
| Board family | Rockchip RK3562 / RK817 |
| Architecture | AArch64 |
| Internal storage | Approximately 116.5 GiB eMMC |
| Removable storage | Approximately 29.1 GiB microSD |
| Display | DSI, 800×1280, rotated 90 degrees |
| NPU | Rockchip NPU accessible through RKNN and RKLLM |
| GPU | Mali device exposed as `/dev/mali0` |
| Media hardware | Rockchip MPP, RGA, ISP-related devices |
| Audio | RK817 codec and internal microphone |
| Touchscreen | GSL3673 family |

### 2.2 Current Kernel

```text
Linux 6.1.118
Build: #131
Build timestamp: Sun Apr 12 17:53:23 CEST 2026
Architecture: aarch64
```

The prior environment used Linux 6.1.118 `#2`. The exact old kernel image has not been recovered. However, the complete old and current loadable module trees were compared and found to be byte-identical. The current `#131` kernel boots the tablet and supports the NPU, audio, display, storage, and media devices.

### 2.3 Storage Layout

**microSD: `/dev/mmcblk0`**

| Partition | Approximate size | Filesystem | Purpose |
|---|---|---|---|
| `/dev/mmcblk0p1` | 464.5 KiB | unknown/raw | low-level boot data |
| `/dev/mmcblk0p2` | 4 MiB | unknown/raw | low-level boot data |
| `/dev/mmcblk0p3` | 256 MiB | VFAT | kernel, device trees, extlinux configuration |
| `/dev/mmcblk0p4` | 28.9 GiB | ext4 | independent Debian rescue root |

**internal eMMC: `/dev/mmcblk2`**

The eMMC retains many vendor partitions. The active Debian root is:

```text
/dev/mmcblk2p25
Filesystem: ext4
Label: internal-data
Approximate size: 110.4 GiB
Mountpoint: /
```

### 2.4 Root PARTUUIDs

Normal eMMC root:

```text
86190000-0000-4d2d-8000-7ad7000056e0
```

SD rescue root:

```text
c0ffee11-2233-4455-6677-8899aabbccdd
```

---

## 3. Boot Design

### 3.1 Normal Boot

```text
microSD bootloader
    -> /Image on microSD
    -> /rk3562.dtb on microSD
    -> root=PARTUUID=86190000-0000-4d2d-8000-7ad7000056e0
    -> /dev/mmcblk2p25 mounted as /
```

### 3.2 Rescue Boot

```text
microSD bootloader
    -> /Image on microSD
    -> /rk3562.dtb on microSD
    -> root=PARTUUID=c0ffee11-2233-4455-6677-8899aabbccdd
    -> /dev/mmcblk0p4 mounted as /
```

### 3.3 Extlinux Entries

The boot menu contains at least:

- `samwise_emmc`
- `samwise_emmc_debug`
- `samwise_emmc_fallback`
- `sd_rescue`
- `sd_rescue_debug`
- `sd_rescue_fallback`

The cloned SD is presently configured with:

```text
default samwise_emmc
```

This is temporary so the eMMC system can mount and modify the rescue root.

---

## 4. Recovery Process

### 4.1 Failed Armbian Attempt

An Armbian image produced:

- a black screen;
- no SSH access;
- no confirmed usable Linux boot.

Removing the SD caused the tablet to enter Android recovery rather than a normal Android userspace.

**Assessment at the time.** The image was assumed broadly incompatible with the
tablet's boot chain, device tree, panel, PMIC configuration and partition scheme.

**Solution at the time.** A known-working `tech4bot/rk3562deb` Doogee U10 image
was used as the recovery boot source.

> **Superseded 2026-07-27 — see [section 4.6](#46-armbian-panel-resolution-2026-07-27).**
> The broad-incompatibility assessment above was wrong. The boot chain, U-Boot,
> kernel, storage and PMIC were all fine. A single defect — the DSI panel wired
> to the wrong GPIO bank in the device tree — accounted for the entire symptom.
> Armbian now boots on this tablet with the panel lit.

**Architectural conclusion.** Generic Rockchip or ARM64 compatibility is not enough for this device. Bootloader, device tree, panel initialization, PMIC behavior, and storage layout must be treated as a single hardware-enablement bundle. The corollary, learned the hard way here: a black screen is one bit of information. It says nothing about which layer failed, and the instinct to read it as "broadly incompatible" cost roughly a week of treating Armbian as a dead end when it was one devicetree property away from working.

### 4.6 Armbian Panel Resolution (2026-07-27)

**Root cause.** The vendor DTS describes the Rockchip *reference* tablet, which
drives the DSI panel from GPIO0. The Doogee U10 reuses the same board name,
model string and `compatible`, but wires enable/reset to GPIO4. On real U10
hardware the reference pins do nothing, so the panel never leaves reset and
never powers up — a black screen behind an otherwise healthy boot.

```text
                          enable-gpios        reset-gpios
factory Android DTB       gpio4 RK_PB6        gpio4 RK_PB5     <- real wiring
running 6.1.118 DTB       gpio4 RK_PB6        gpio4 RK_PB5     <- real wiring
rk3562deb overlay/ DTS    gpio4 RK_PB6        gpio4 RK_PB5     <- real wiring
rockchip-linux develop-6.1  gpio0 RK_PB0      gpio0 RK_PC4     <- reference board
armbian linux-rockchip      gpio0 RK_PB0      gpio0 RK_PC4     <- reference board
```

Alongside the GPIOs, the reference DTS also omits `power-supply` (the
`vcc3v3_lcd_n` rail is commented out upstream), `rotation`, `bpc`, `bus-format`,
`compatible-lcd` and `lcd1-id`, and selects `MIPI_DSI_MODE_EOT_PACKET` where the
factory tree uses `MIPI_DSI_CLOCK_NON_CONTINUOUS` (`dsi,flags` 0xa03 vs 0xc03).
`panel-init-sequence` is byte-identical in both.

**Where the correct wiring lives.** Not upstream. `tech4bot/rk3562deb` maintains
it in `overlay/arch/arm64/boot/dts/rockchip/`, which `build.sh:454` copies over
the cloned kernel tree before compiling. Anyone building this tablet from a
stock vendor kernel will hit the same black screen.

**Fix.** `userpatches/kernel/rk35xx-vendor-6.1/fix-rk3562-tablet-panel-doogee-u10.patch`
in the ArmbianBuild fork (commit `a6de456`). An earlier blob-substitution
extension (commit `1ef5c10`) is the approach that was actually booted on
hardware and is retained in history as a fallback.

**Verification method, for reuse.** Compiling the *unpatched* DTS with `dtc -@`
reproduced the shipped DTB byte for byte, which establishes the toolchain as
faithful; the patched DTS then yielded a display subtree semantically identical
to the known-good DTB, with the only raw differences being phandle numbers that
each resolve to the same node. This validates a devicetree change in seconds
rather than waiting hours for a build and a boot.

**Status.** Panel confirmed working on hardware. The tablet now stops at
Armbian's first-boot prompt — see [section 4.7](#47-armbian-first-boot-trap).

### 4.7 Armbian First-Boot Trap

With the panel working, the tablet reaches the Armbian splash and stops with a
frozen spinner. This is not a hang. `/root/.not_logged_in_yet` is present, so
`armbian-firstlogin` runs and blocks waiting for interactive input — root
password, user creation, locale, timezone — while the kernel command line names
`console=ttyS0,1500000n8` and nothing else. The prompt is going to a serial port
with nothing attached, and `splash` plus `plymouth.ignore-serial-consoles` keeps
Plymouth on the panel, whose spinner stops animating once boot blocks.

**Trap within the trap.** Preseeding via `PRESET_*` variables does not help by
itself. `armbian-firstlogin:674` exits immediately unless the login session is
on `tty1`:

```bash
if [ -z "$PRESET_ROOT_PASSWORD" ]; then
    read_password "Create root"
else
    if [ "$(who am i | awk '{print $2}')" != "tty1" ]; then
        exit
    fi
```

A correct-looking preseed on this command line silently does nothing.

**Chosen approach.** Bypass firstlogin rather than feed it: delete
`/root/.not_logged_in_yet`, pre-place Conrad's public key in
`/root/.ssh/authorized_keys` (`PermitRootLogin yes` and `PubkeyAuthentication yes`
are already set, with no drop-ins overriding), pre-seed a NetworkManager keyfile
for wifi, and add `console=tty1` while removing `splash` so the panel becomes a
usable fallback console.

**Note.** The image ships root with Armbian's default password `1234`, unlocked,
with password authentication enabled. Change it at first login or set one at
injection time; until then anything on the LAN can try it.

### 4.2 Recovery of the eMMC Debian Root

After booting the known-good SD, the active root was checked with:

```bash
findmnt -no SOURCE,TARGET /
```

Verified result:

```text
/dev/mmcblk2p25 /
```

The complete topology was inspected with:

```bash
lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINTS \
  /dev/mmcblk0 /dev/mmcblk2
```

This established that the system was using:

```text
SD bootloader + SD kernel/DTB -> eMMC Debian root
```

### 4.3 Creation of a Verified Golden Backup

A complete SD image was created: **[verified on Conrad]**

```text
/home/frodo/backups/samwise/verified/verified-sd-20260725-182727/
    samwise-sd-full-20260725-182727.img.zst
```

Uncompressed source size:

```text
31,268,536,320 bytes
```

Compressed size:

```text
12,634,846,192 bytes
```

SHA-256:

```text
a924d9540fa7ff75ed39ddafa64fc3f74613837845897949953a7fd0656741d4
```

Validation performed:

- `zstd -t` passed on Samwise;
- SHA-256 validation passed on Samwise;
- copied archive validated independently on Conrad;
- boot assets and extlinux configuration were preserved with the image.

The archive directory also carries the boot assets alongside the image, which makes it the reference source for the device-tree comparison in section 7.6: **[verified on Conrad]**

```text
Image                    40,608,256 bytes
rk3562.dtb                  152,925 bytes
rk3562-fallback.dtb         152,793 bytes
extlinux/
manifest.txt
samwise-sd-full-20260725-182727.img.zst.sha256
```

This is now the authoritative golden recovery image.

### 4.4 Rejection of Older Backup Artifacts

An older backup directory contained:

- a supposed compressed image listed as only 13 bytes;
- an incomplete `.partial` file;
- a zstd premature-end error.

These files are not acceptable recovery sources.

**Operational rule.** Never flash or rely on:

```text
samwise-microsd-20260607-181241.img.zst
samwise-microsd-20260607-181319.img.zst.partial
```

The verified 2026-07-25 image supersedes them.

### 4.5 Creation of a Rescue Clone

The verified image was flashed to a second microSD card. The clone's purpose is to become a dedicated rescue card while preserving the golden card.

The clone was changed to:

```text
default sd_rescue
```

After booting, the device:

- appeared on the network;
- responded at `192.168.11.167`;
- presented a new ED25519 SSH host key; **[verified on Conrad — `~/.ssh/known_hosts.samwise-rescue`, ed25519, written 2026-07-25 21:48]**
- rejected the `chaos` login because only public-key authentication was allowed.

This strongly suggests that the independent rescue userspace booted. It is not yet final proof, because an authenticated session has not confirmed `/dev/mmcblk0p4` as `/`.

---

## 5. Problem and Solution Register

### 5.1 Problem: Uncertainty About the Active Root

A boot from microSD does not necessarily mean the root filesystem is on microSD. The kernel and root may come from different devices.

**Solution.** Always inspect both:

```bash
findmnt -no SOURCE,TARGET,FSTYPE,OPTIONS /
grep -o 'root=[^ ]*' /proc/cmdline
```

A boot path is not considered proven until both outputs agree.

### 5.2 Problem: Risk of Modifying the Only Working Card

Testing rescue entries on the golden SD would increase recovery risk.

**Solution.** Maintain distinct media:

```text
Golden SD:
- verified
- minimal writes
- normal eMMC boot default

Rescue clone:
- modifiable
- rescue root default after validation
```

Recommended physical labels:

```text
SAMWISE GOLDEN BOOT — DO NOT MODIFY
SAMWISE RESCUE — BOOTS SD ROOT
```

### 5.3 Problem: Windows Offered to Format the SD

Windows could not interpret the ext4 rescue partition and offered to format it.

**Solution.** Do not format or initialize the disk.

The card was positively identified as:

```text
Disk 11
TS-RDF5 SD Transcend
GPT
29.12 GB
```

The accessible boot partition was:

```text
Partition 3
256 MB
VFAT/Basic
Drive letter U:
```

Only this file should be edited from Windows:

```text
U:\extlinux\extlinux.conf
```

### 5.4 Problem: Extlinux Syntax Was Entered as PowerShell

The line:

```text
default samwise_emmc
```

was entered at the PowerShell prompt and produced a command-not-found error.

**Cause.** `default samwise_emmc` is an extlinux configuration directive, not a shell command.

**Solution.** Edit the file programmatically:

```powershell
$Cfg = 'U:\extlinux\extlinux.conf'
$Text = [System.IO.File]::ReadAllText($Cfg)

$Text = [regex]::Replace(
  $Text,
  '(?m)^default\s+\S+',
  'default samwise_emmc'
)

$Ascii = [System.Text.ASCIIEncoding]::new()
[System.IO.File]::WriteAllText($Cfg, $Text, $Ascii)
```

The file was restored and verified to begin with:

```text
default samwise_emmc
timeout 50
menu title RK3562 Boot
```

### 5.5 Problem: Rescue SSH Authentication Failed

Observed result:

```text
chaos@192.168.11.167: Permission denied (publickey)
```

**Interpretation.** This is not a boot, network, or SSH-daemon failure. It indicates:

- the tablet reached userspace;
- networking was available;
- SSH was listening;
- password login was unavailable or disabled;
- Conrad's key was not authorized.

**Solution.**

1. Boot the clone with `default samwise_emmc`.
2. Mount `/dev/mmcblk0p4`.
3. Add Conrad's public key to the rescue `chaos` account.
4. Restore `default sd_rescue`.
5. Reboot and authenticate.
6. Prove the root with `findmnt` and `/proc/cmdline`.

### 5.6 Problem: Armbian Versus Debian Identity

The prior environment was described as Armbian, but:

- `/etc/armbian-release` was absent;
- the active system identified as Debian Bookworm;
- the available project tree was a sysroot/cross-build environment;
- no complete tablet Armbian build was located.

**Conclusion.** The current system should be documented as a custom Debian/RK3562 environment, not as a confirmed Armbian installation.

### 5.7 Problem: Historical Kernel Image Missing

The older running kernel was:

```text
Linux 6.1.118 #2
```

The current kernel is:

```text
Linux 6.1.118 #131
```

The old `#2` `Image` file is not currently available.

**Evidence reducing the risk:**

- Both kernels use release 6.1.118.
- Old and current module trees are byte-identical.
- Current display, storage, audio, NPU, and media access work.
- RKNN and RKLLM execute successfully.

**Decision.** Use 6.1.118 `#131` as the operational baseline unless a specific regression is demonstrated.

### 5.8 Problem: Stale Audio Service Dependency

The transcription service referenced:

```text
Requires=mnt-sd\x2dbackup.mount
After=mnt-sd\x2dbackup.mount
```

This mount no longer represents the correct storage design and could conflict with the SD rescue root.

**Solution.** The service was disabled:

```text
enabled state: disabled
active state: inactive
failed units: 0
```

The output directory was changed to eMMC-backed storage:

```text
/home/frodo/audio-transcripts
```

The stale mount dependency must be removed before the service is enabled again.

### 5.9 Problem: Invalid RKNN Model

The original model:

```text
wav2vec2-5s-fp.rknn
```

failed with:

```text
RKNN_ERR_MODEL_INVALID
```

Observed file size:

```text
125,378,560 bytes
```

Internal declared size:

```text
194,469,888 bytes
```

**Conclusion.** The model is truncated, corrupt, or incomplete.

**Solution.** Do not use it. Two other models initialize:

```text
wav2vec2-5s-hybrid.rknn
wav2vec2-5s-w8a8.rknn
```

### 5.10 Problem: W8A8 Model Emits Only Blank CTC Frames

**Results.**

Hybrid without normalization:

```text
blank frames: 202/249
blank percentage: 81.1%
decoded:
I PAN MAKA GOD WILL A AWAKEMALL A AO
```

Hybrid with normalization:

```text
blank frames: 228/249
blank percentage: 91.6%
decoded:
AI    G WEL MM
```

W8A8 without normalization:

```text
blank frames: 249/249
blank percentage: 100%
decoded:
''
```

W8A8 with normalization:

```text
blank frames: 249/249
blank percentage: 100%
decoded:
''
```

**Interpretation.** The W8A8 model is unusable with the current preprocessing and quantization contract. It does execute, but every frame resolves to the CTC blank token.

**Likely causes:**

- calibration data mismatch;
- incorrect input quantization;
- wrong waveform normalization;
- wrong expected tensor scale;
- final CTC projection damaged by quantization;
- mismatch between conversion pipeline and runtime input type;
- nonrepresentative calibration speech;
- layer sensitivity requiring hybrid quantization.

**Decision.** Use the hybrid model for functional debugging. Do not deploy W8A8 until it passes a nonblank self-test.

### 5.11 Problem: Hybrid ASR Output Is Poor

The hybrid model reacts to the waveform but produces poor text.

**Known-good lower layers:**

- PipeWire capture works.
- Internal microphone works.
- 16 kHz mono WAV capture works.
- RKNN runtime works.
- NPU driver works.
- Model loads.
- Logits are returned.
- CTC decoder mechanically works.

**Remaining likely causes:**

- model conversion loss;
- vocabulary mismatch;
- incorrect blank-token assumptions;
- weak greedy decoding;
- missing language-model rescoring;
- preprocessing mismatch;
- source model quality;
- domain mismatch;
- excessive quantization in sensitive layers.

---

## 6. Current Verified State

### Verified

- SD boot chain works.
- eMMC Debian root works.
- `/dev/mmcblk2p25` mounts as `/`.
- SD rescue root exists at `/dev/mmcblk0p4`.
- SD boot partition exists at `/dev/mmcblk0p3`.
- Complete SD backup exists and is cryptographically verified.
- Clone is recognized correctly by Windows.
- Extlinux configuration has been repaired.
- RKNN Lite 2.3.2 initializes.
- RKNPU driver 0.9.8 is active.
- RKLLM runtime 1.2.3 works.
- Qwen3 0.6B RKLLM inference works.
- Internal microphone captures measurable audio.
- Hybrid ASR model produces nonblank logits.
- W8A8 model produces all blanks.
- Invalid FP model has been identified.
- Broken transcription service is disabled.
- Current failed systemd unit count is zero.
- **Armbian boots on this tablet with the DSI panel lit** (2026-07-27), using an
  image whose DTB was replaced with the known-good one.
- Panel root cause identified, corroborated by three independent sources, and
  fixed at DTS source rather than by blob substitution.

### Not yet fully verified

- The DTS patch (`a6de456`) itself — verified by compilation and DTB comparison,
  but the image that actually booted carried the blob swap. The next full
  rebuild is its first hardware test; `git revert a6de456` is the fallback.
- Armbian first boot past `armbian-firstlogin` (see section 4.7).
- Armbian wifi association, SSH reachability, and any hardware-matrix row on the
  Armbian image. Everything in the matrix remains unrecorded on both images.
- Authenticated rescue login.
- `/dev/mmcblk0p4` proven as active `/`.
- Rescue account key ownership and permissions.
- Corrected systemd service.
- Intelligible ASR output.
- Source-model reference comparison.
- Old versus current device-tree semantic comparison.
- Sustained NPU thermal stability.
- Reboot persistence after final service changes.

---

## 7. Immediate Next Steps

### 7.1 Complete Rescue Authentication

#### Flush and eject the clone

In Administrator PowerShell:

```powershell
Write-VolumeCache U

Remove-PartitionAccessPath `
  -DiskNumber 11 `
  -PartitionNumber 3 `
  -AccessPath 'U:\'
```

Then safely eject the SD reader. Ignore and cancel any Windows request to format another partition.

#### Boot with the eMMC entry

Insert the cloned SD currently configured with:

```text
default samwise_emmc
```

Boot and confirm:

```bash
findmnt -no SOURCE,TARGET /
```

Expected:

```text
/dev/mmcblk2p25 /
```

#### Copy Conrad's key

On Conrad:

```bash
test -f ~/.ssh/id_ed25519.pub ||
    ssh-keygen -y \
      -f ~/.ssh/id_ed25519 \
      > ~/.ssh/id_ed25519.pub

scp ~/.ssh/id_ed25519.pub \
    samwise:/tmp/conrad-rescue.pub
```

> **Prerequisite.** Conrad's `~/.ssh/config` currently defines only `Host skarabrae`;
> there is no `samwise` entry. Either add one or substitute the tablet's address
> for `samwise:` in the `scp` target. See [Appendix A](#appendix-a--transcription-verification-log).

#### Mount the rescue root

On Samwise:

```bash
set -euo pipefail

[[ "$(findmnt -no SOURCE /)" == "/dev/mmcblk2p25" ]] || {
    echo "ERROR: not running from eMMC"
    exit 1
}

sudo mkdir -p /mnt/sd-rescue
sudo mount /dev/mmcblk0p4 /mnt/sd-rescue
```

#### Identify the rescue account

```bash
grep '^chaos:' /mnt/sd-rescue/etc/passwd

CHAOS_UID="$(
    awk -F: '$1=="chaos"{print $3}' \
      /mnt/sd-rescue/etc/passwd
)"

CHAOS_GID="$(
    awk -F: '$1=="chaos"{print $4}' \
      /mnt/sd-rescue/etc/passwd
)"

CHAOS_HOME="$(
    awk -F: '$1=="chaos"{print $6}' \
      /mnt/sd-rescue/etc/passwd
)"

[[ -n "$CHAOS_UID" && -n "$CHAOS_GID" && -n "$CHAOS_HOME" ]] || {
    echo "ERROR: chaos account not found"
    sudo umount /mnt/sd-rescue
    exit 1
}
```

#### Install the public key

```bash
SSH_DIR="/mnt/sd-rescue${CHAOS_HOME}/.ssh"
AUTH="${SSH_DIR}/authorized_keys"
KEY="$(cat /tmp/conrad-rescue.pub)"

sudo install -d \
  -m 0700 \
  -o "$CHAOS_UID" \
  -g "$CHAOS_GID" \
  "$SSH_DIR"

sudo touch "$AUTH"

if ! sudo grep -qxF "$KEY" "$AUTH"; then
    printf '%s\n' "$KEY" |
      sudo tee -a "$AUTH" >/dev/null
fi

sudo chown "$CHAOS_UID:$CHAOS_GID" "$AUTH"
sudo chmod 0600 "$AUTH"

sudo ssh-keygen -lf "$AUTH"

sync
sudo umount /mnt/sd-rescue
```

#### Set the clone back to rescue

```bash
set -euo pipefail

sudo mkdir -p /mnt/samwise-boot
sudo mount /dev/mmcblk0p3 /mnt/samwise-boot

CFG=/mnt/samwise-boot/extlinux/extlinux.conf

sudo cp -a \
  "$CFG" \
  "$CFG.before-final-rescue-$(date +%Y%m%d-%H%M%S)"

sudo sed -i \
  's/^default .*/default sd_rescue/' \
  "$CFG"

grep '^default ' "$CFG"
grep -A3 '^label sd_rescue$' "$CFG"

sync
sudo umount /mnt/samwise-boot
sudo reboot
```

You should see:

```text
default sd_rescue
```

#### Connect from Conrad

```bash
ssh \
  -i "$HOME/.ssh/id_ed25519" \
  -o IdentitiesOnly=yes \
  -o UserKnownHostsFile="$HOME/.ssh/known_hosts.samwise-rescue" \
  chaos@192.168.11.167
```

#### Final rescue proof

```bash
hostname
whoami
uname -a

findmnt -no SOURCE,TARGET,FSTYPE,OPTIONS /
grep -o 'root=[^ ]*' /proc/cmdline

lsblk -o NAME,SIZE,FSTYPE,LABEL,PARTUUID,MOUNTPOINTS \
  /dev/mmcblk0 /dev/mmcblk2

systemd-analyze
systemctl --failed
```

Acceptance results:

```text
/dev/mmcblk0p4 / ext4 ...
```

and:

```text
root=PARTUUID=c0ffee11-2233-4455-6677-8899aabbccdd
```

### 7.2 Preserve the Rescue Card

After successful validation:

- leave it configured with `default sd_rescue`;
- label it `SAMWISE RESCUE — BOOTS SD ROOT`;
- store it separately from the golden card;
- document the authorized key fingerprint;
- record the image SHA-256 and test date;
- do not use it as a routine development card.

### 7.3 Repair the Transcription Service

The service must remain disabled until manual inference is useful.

Recommended unit design:

```ini
[Unit]
Description=Samwise RKNN Audio Transcription
After=local-fs.target pipewire.service
Wants=pipewire.service

[Service]
Type=simple
User=frodo
Group=frodo
WorkingDirectory=/home/frodo/src/audio-npu
Environment=AUDIO_TRANSCRIBE_MODEL=/home/frodo/src/crispasr-rknpu-spike/wav2vec2-5s-hybrid.rknn
Environment=AUDIO_TRANSCRIBE_OUTPUT=/home/frodo/audio-transcripts
ExecStart=/home/frodo/venvs/rknn/bin/python /home/frodo/src/audio-npu/audio_transcribe.py
Restart=on-failure
RestartSec=10
StartLimitIntervalSec=300
StartLimitBurst=3

[Install]
WantedBy=multi-user.target
```

Required changes:

- remove `mnt-sd\x2dbackup.mount`;
- select the hybrid model explicitly;
- write output to eMMC;
- validate model presence and hash before inference;
- log runtime and driver versions;
- add a CTC blank-ratio health check;
- avoid uncontrolled restart loops.

### 7.4 Establish a CPU Reference ASR Pipeline

Before another RKNN conversion, run the original source model against the exact same WAV and record:

- logits;
- token IDs;
- blank-frame percentage;
- greedy decode;
- beam-search decode;
- character error rate;
- word error rate.

Compare:

| Pipeline | Purpose |
|---|---|
| Source model, raw waveform | baseline |
| Source model, normalized waveform | preprocessing check |
| RKNN hybrid, raw waveform | conversion loss |
| RKNN hybrid, normalized waveform | normalization effect |
| RKNN W8A8, raw waveform | quantized failure |
| RKNN W8A8, normalized waveform | quantized failure |

Useful metrics:

- top-1 token agreement;
- cosine similarity of logits;
- blank-logit margin;
- output entropy;
- nonblank-token diversity;
- WER and CER.

### 7.5 Verify the W8A8 Quantization Contract

Inspect RKNN tensor metadata:

- input type;
- shape;
- layout;
- scale;
- zero point;
- quantization scheme;
- output quantization;
- static-shape expectations.

Verify whether the runtime expects:

- float32 waveform;
- int8 waveform;
- raw PCM values;
- normalized values;
- prequantized input.

Re-export using representative 16 kHz speech. Consider keeping these parts in higher precision:

- early feature extractor;
- normalization layers;
- final CTC projection;
- any layer showing strong source-versus-RKNN divergence.

### 7.6 Compare Device Trees

The archived DTB is preserved in the verified backup directory alongside the image
(`rk3562.dtb`, `rk3562-fallback.dtb`) — see section 4.3.

Decompile the archived and current DTBs:

```bash
dtc -I dtb -O dts \
  -o old-running.dts \
  old-running.dtb

dtc -I dtb -O dts \
  -o current.dts \
  rk3562.dtb

diff -u old-running.dts current.dts
```

Review:

- NPU;
- clocks;
- power domains;
- RK817 audio;
- touchscreen;
- DSI panel;
- ISP and camera nodes;
- regulators;
- reserved memory;
- thermal zones;
- IOMMU;
- SD/eMMC timing.

---

## 8. Risk Register

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Golden card modified accidentally | Medium | High | Label and isolate it |
| Wrong disk selected for flashing | Medium | Critical | Verify model, size, and bus before write |
| Windows formats ext4 partition | Medium | Critical | Cancel all format prompts |
| Rescue remains inaccessible | Medium | Medium | Install SSH key offline |
| Rescue entry not selected | Medium | Medium | Verify extlinux and `/proc/cmdline` |
| eMMC filesystem corruption | Low–Medium | Critical | No fsck while mounted; maintain rescue |
| Invalid model reused | Medium | Medium | Hash and quarantine known-bad model |
| W8A8 silently emits blanks | High | Medium | Add blank-ratio self-test |
| Service restart loop | Medium | Medium | Start limits and validation |
| NPU thermal throttling | Unknown | Medium | Log temperature and inference rate |
| Device-tree regression | Low | High | Preserve working DTBs |
| Backup archive loss | Low | High | Maintain two verified copies |

---

## 9. Operational Guardrails

Do not perform these actions without a separately reviewed plan:

```text
armbian-install
factory reset
mkfs on eMMC
dd to /dev/mmcblk2
fsck on mounted /
Windows disk initialize
Windows disk clean
Windows format of Linux partitions
blind writes to WSL /dev/sdX devices
```

Before any destructive storage command:

```bash
lsblk -o NAME,MODEL,SERIAL,SIZE,TYPE,FSTYPE,MOUNTPOINTS
findmnt /
```

Conrad's 1 TiB WSL disks are not the tablet SD and must never be selected based only on a `/dev/sdX` name.

---

## 10. Acceptance Criteria

### Recovery complete

- [ ] Golden SD remains verified and unchanged.
- [ ] Rescue clone boots independently.
- [ ] `/dev/mmcblk0p4` is proven as `/`.
- [ ] `/proc/cmdline` contains the rescue PARTUUID.
- [ ] Conrad authenticates with a separate rescue known-hosts file.
- [ ] eMMC is visible from rescue.
- [ ] Rescue boot has no unexplained failed units.
- [ ] Rescue card is physically labeled.
- [ ] Recovery procedure is stored offline.
- [ ] Two verified image copies exist.

### Normal Samwise platform

- [ ] SD boot chain works.
- [ ] eMMC root works.
- [ ] `frodo` can authenticate.
- [ ] networking works.
- [ ] failed systemd unit count is zero.
- [ ] NPU devices exist.
- [ ] RKNN inference initializes.
- [ ] RKLLM inference initializes.

### Audio transcription

- [ ] microphone records audio.
- [ ] RKNN model loads.
- [ ] inference executes.
- [ ] logits are produced.
- [ ] transcript is intelligible.
- [ ] source-model baseline exists.
- [ ] quantization contract is documented.
- [ ] deployed model passes blank-ratio self-test.
- [ ] service has no stale mount dependency.
- [ ] service survives reboot.
- [ ] output is stored on eMMC.
- [ ] quality and performance metrics are logged.

---

## 11. Senior Architecture Assessment

Samwise is now a viable experimental edge-AI platform but not yet an appliance-grade system.

The hardware layer is substantially healthy:

```text
boot: working
eMMC: working
display: working
microphone: working
NPU: working
RKNN: working
RKLLM: working
```

The remaining work is primarily above the kernel:

```text
recovery authentication
service orchestration
model provenance
quantization quality
decoder quality
observability
documentation
```

The platform should be managed in layers:

```text
Applications
    audio transcription
    CrispASR
    local LLM demos

Model artifacts
    RKNN files
    RKLLM files
    vocabularies
    hashes
    conversion metadata

AI runtimes
    RKNN Lite
    RKLLM
    CTC decoder

Linux services
    systemd
    PipeWire
    logging
    health checks

Kernel and device tree
    Linux 6.1.118
    RK3562 DTB
    RKNPU
    RK817 audio

Storage and boot
    SD boot chain
    eMMC normal root
    SD rescue root

Hardware
    RK3562
    RK817
    eMMC
    microSD
    microphone
    display
```

Each layer must be tested independently. A poor transcript is not proof of an NPU failure. An SSH-key rejection is not proof of a rescue-boot failure. A compressed file existing is not proof of a valid backup.

---

## 12. Final Recommended Sequence

1. Insert the cloned SD configured for `samwise_emmc`.
2. Boot Samwise.
3. Confirm `/dev/mmcblk2p25` is `/`.
4. Copy Conrad's public key to Samwise.
5. Mount `/dev/mmcblk0p4`.
6. Install the key for `chaos`.
7. Verify key ownership, mode, and fingerprint.
8. Unmount the rescue root.
9. Mount `/dev/mmcblk0p3`.
10. Set `default sd_rescue`.
11. Unmount and reboot.
12. Authenticate from Conrad.
13. Confirm `/dev/mmcblk0p4` is `/`.
14. Confirm the rescue PARTUUID in `/proc/cmdline`.
15. Check `systemctl --failed`.
16. Power off cleanly.
17. Label and preserve the rescue card.
18. Return to the normal eMMC boot card.
19. Resume ASR work with the hybrid model.
20. Build a source-model reference before another W8A8 conversion.

---

## 13. Conclusion

The recovery process transformed an uncertain boot failure into a controlled, recoverable architecture with:

- a working eMMC Debian root;
- a known-good SD boot chain;
- a verified full SD image;
- a separate rescue clone;
- functioning RKNN and RKLLM runtimes;
- working microphone capture;
- clearly isolated ASR model problems.

The remaining recovery issue is authentication, not bootloader repair. The remaining AI issue is model validation and quantization, not NPU enablement.

Current status:

```text
Boot chain:       working
eMMC root:        working
SD rescue root:   likely booting; authentication pending
Backup:           verified
Kernel/modules:   working
NPU driver:       working
RKNN runtime:     working
RKLLM runtime:    working
Microphone:       working
ASR hybrid model: executes but inaccurate
ASR W8A8 model:   executes but produces all blanks
ASR service:      disabled pending repair
Armbian boot:     working; panel lit (2026-07-27)
Armbian panel:    fixed at DTS source; patch not yet boot-tested
Armbian login:    blocked at first-boot prompt (section 4.7)
```

**Amendment, 2026-07-27.** The framing above — that the remaining recovery issue
is authentication and the remaining AI issue is model quantization — still holds,
but it was written while Armbian was believed to be a dead end. It is not. The
Armbian track is now the closest it has ever been to a usable native image: the
boot chain, the panel, and the kernel all work, and what stands between the
current state and a login is a first-boot prompt on an unattached serial port.

Samwise should now be managed as a recoverable embedded AI platform with explicit validation gates, preserved artifacts, and layer-specific diagnostics.

---

## Appendix A — Transcription Verification Log

Checks performed on Conrad on 2026-07-27 while transcribing this document into the repository.

### Correction applied

The source document gave the golden backup path as
`/home/frodo/samwise-backups/verified-sd-20260725-182727/`.
**That directory does not exist on Conrad.** The archive is real and intact, but lives at:

```text
/home/frodo/backups/samwise/verified/verified-sd-20260725-182727/
```

Section 4.3 has been corrected to the actual path. A wrong path in a recovery playbook is
a recovery failure, so this was fixed rather than footnoted.

### Confirmed unchanged

| Claim | Result |
|---|---|
| Compressed size 12,634,846,192 bytes | exact match |
| SHA-256 `a924d954…41d4` | exact match against the archive's own `.sha256` sidecar |
| `manifest.txt` records host `samwise`, kernel `6.1.118 #131 SMP Sun Apr 12 17:53:23 CEST 2026 aarch64` | matches sections 2.2 and 4.3 |
| Boot assets preserved beside the image | `Image`, `rk3562.dtb`, `rk3562-fallback.dtb`, `extlinux/` all present |
| Rescue host key was recorded | `~/.ssh/known_hosts.samwise-rescue` exists, ed25519, hashed hostname, written 2026-07-25 21:48 |
| `~/.ssh/id_ed25519.pub` exists | present — the `ssh-keygen -y` fallback in section 7.1 will be a no-op |

### Open discrepancy — not corrected

Section 7.1 uses `scp … samwise:/tmp/conrad-rescue.pub` and `ssh samwise`. Conrad's
`~/.ssh/config` defines only `Host skarabrae` — there is **no `samwise` entry**. Those
commands will only work if `samwise` resolves via DNS or mDNS. Add a `Host samwise`
block, or substitute the tablet's IP address, before running section 7.1.

### Unverified by design

Everything on the tablet itself — partition table, PARTUUIDs, extlinux contents, RKNN/RKLLM
runtime versions, ASR blank-frame percentages — was not re-checked, as Samwise was not
contacted during transcription. Those remain as reported by the source session.
