# 01 — Hardware & Software Baseline

## The device

| Attribute | Value |
|---|---|
| Hostname | `samwise` |
| Product | Doogee U10-class tablet |
| SoC | Rockchip RK3562 — 4× Cortex-A53 @ 2.0 GHz |
| GPU | Mali-G52-2EE |
| NPU | Rockchip RKNN unit, 1 TOPS INT8, at `0xff300000` |
| PMIC / power | Rockchip RK817 tablet power stack |
| Display | 800×1280 DSI panel, needs `rotate=90` for landscape |
| Touch | GSL3673-class |
| Board identity | `RK3562 RK817 TABLET LP4 Board` |
| Stock OS | Debian GNU/Linux 12 Bookworm, ARM64 |
| Stock kernel | 6.1.118 (vendor-derived) |
| eMMC | ~116.5 GiB, holds vendor Android — **never written** (D002) |

## The build host

`Conrad` — WSL2 Ubuntu 24.04 on x86_64. Notes that matter in practice:

- **No Docker installed.** Armbian falls back to sudo for native builds, so
  `compile.sh` must run in an interactive terminal that can answer the sudo
  password prompt. It cannot run from a non-interactive agent shell.
- **mDNS does not resolve from WSL2**: `ssh frodo@samwise` fails with
  "Could not resolve hostname" on Conrad even when the tablet is up. Use the
  tablet's IP address, or run device-side commands from a direct SSH session.
- A restricted `samwise-build` user exists for builds (provisioned by
  `~/samwise_dev/setup_samwise_build_user.sh`): ACL-scoped to the ArmbianBuild
  repo, sudo only through a validating apt wrapper.

## Captured NPU provenance (stock device, 2026-07-04)

These are the numbers every compatibility decision hangs on:

| Component | Version | How captured |
|---|---|---|
| RKNPU kernel driver | **v0.9.8** | `sudo cat /sys/kernel/debug/rknpu/version` |
| librknnrt runtime | **2.3.2** (`429f97ae6b@2025-04-09`) | `grep -aoh 'librknnrt version[^)]*)' /usr/lib/librknnrt.so` |
| NPU devfreq | `ff300000.npu`, governor `rknpu_ondemand`, 1 GHz | `baseline/current-system/sysfs/npu-devfreq.txt` |
| RKLLM runtime | present and known-working on stock | spec statement + matrix row 18 |

**The version contract:** `librknnrt` enforces a minimum kernel-driver version.
RKLLM's documented minimum is driver **≥ 0.9.8**. Plain RKNN typically runs on
a one-step-older driver with a warning; RKLLM does not. This is why the build
carries a 0.9.8 driver backport (see [03 — NPU Enablement](03-npu-enablement.md)).

## Stock device-tree facts (from `baseline/current-system/device-tree/fdt.dts`)

- `npu@ff300000`: `compatible = "rockchip,rk3562-rknpu"`, `status = "okay"`,
  `rknpu-supply` → the `vdd_npu` regulator
- NPU IOMMU `iommu@ff30a000`: `status = "okay"`
- `vdd_npu`: PWM regulator on pwm6, 800–1100 mV, init 900 mV, always-on,
  supplied from `vcc_sys`

The Armbian-side DTS (`rk3562-rk817-tablet-v10.dts`, from rockchip-linux
develop-6.1) already defines the identical `vdd_npu` regulator; only the
`&rknpu` / `&rknpu_mmu` enables were missing. That gap is what the DT patch
closes.

## Re-capturing the baseline

From a host that can reach the tablet:

```bash
~/repos/rk3562deb/scripts/capture-samwise-baseline.sh
```

The script now also collects NPU provenance (`sysfs/rknpu-driver-version.txt`,
`sysfs/librknnrt-version.txt`, `sysfs/rkllm-runtime.txt`) alongside the
original devfreq/device-node captures. Manual equivalents on the device:

```bash
sudo cat /sys/kernel/debug/rknpu/version
f=$(find /usr/lib /usr/lib64 /usr/local/lib /oem -name 'librknnrt.so*' | head -1)
echo "$f"; grep -aoh 'librknnrt version[^)]*)' "$f" | head -1
dmesg | grep -i rknpu
cat /sys/class/devfreq/ff300000.npu/{governor,cur_freq}
```
