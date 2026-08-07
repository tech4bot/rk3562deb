# 03 — NPU Enablement

How the NPU went from silently dead in the first image to matching the stock
device. Recorded in full because the *method* (compare built artifact against
captured baseline) is the project's core regression defense.

## The bug (found 2026-07-04, before any flash)

The first built image (2026-06-20, vendor 6.1.75) had the NPU disabled:

- `rk3562.dtsi` declares `npu@ff300000` and its IOMMU `iommu@ff30a000` with
  `status = "disabled"` (SoC-dtsi default).
- `rk3562-rk817-tablet-v10.dts` never references `&rknpu` — only
  `rk3562-evb.dtsi` enables it in the vendor tree.
- Decompiling the built DTB confirmed both nodes disabled; the stock DTB dump
  (`baseline/current-system/device-tree/fdt.dts`) showed both `okay` with
  `rknpu-supply` → `vdd_npu`.

Symptom this would have produced on the flashed image: no
`/sys/class/devfreq/ff300000.npu`, no NPU device node, `librknnrt` failing at
init — a P2 test-matrix failure (rows 17–18) with a misleading userspace error.

## Patch 1: device-tree enable

`enable-rknpu-rk3562-rk817-tablet.patch` — adds to the tablet DTS, mirroring
the EVB pattern and the stock DTB:

```dts
&rknpu {
	rknpu-supply = <&vdd_npu>;
	status = "okay";
};

&rknpu_mmu {
	status = "okay";
};
```

`vdd_npu` (PWM regulator, pwm6, 800–1100 mV, always-on) was already defined in
the tablet DTS — only the consumer wiring was missing.

## Patch 2: driver 0.9.7 → 0.9.8 backport

`rknpu-driver-0.9.8-backport.patch` — the pristine upstream commit
`736d89f344156b75393b01ab2c0e3a06c39e110f` from `armbian/linux-rockchip`
branch `rk-6.1-rkr4.1` ("driver: rknpu: Update rknpu driver, version: 0.9.8",
2024-08-28: fixes multi-process run and domain-switch errors; touches six
files, all inside the self-contained `drivers/rknpu/`).

**Why:** the stock device runs driver v0.9.8 with librknnrt 2.3.2, and RKLLM's
documented minimum is driver ≥ 0.9.8. The pinned `rk-6.1-rkr3` tree carries
0.9.7 — RKNN would have run with a warning; RKLLM would have failed. Track A
requires preserving the known-working stack, so the driver is matched to stock.

**Trap that was avoided (do not "fix" this differently):** syncing the whole
`drivers/rknpu/` directory to the 0.9.8 tree state pulls in an intermediate
rk3576 devfreq commit that references `rockchip_opp_set_low_length`, a helper
that does **not exist** in the rkr3 tree — it breaks compilation. The pristine
single-commit patch applies cleanly (`git apply --check` verified) and has no
such dependency.

## Patch locations (keep in sync)

| Layer | Path |
|---|---|
| Canonical (source-controlled overlay) | `rk3562deb/platform/armbian/userpatches/kernel/rk35xx-vendor-6.1/` |
| Direct-build working copy | `~/repos/ArmbianBuild/userpatches/kernel/rk35xx-vendor-6.1/` |

## Verification results

- Kernel package rebuild (2026-07-04, 2:49 min): patch-set hash changed
  (`Pe6e2` → `P6e1c`), build log lists the patch, and the DTB extracted from
  the new `linux-dtb-vendor-rk35xx` deb shows NPU `okay` + `rknpu-supply` →
  `vdd_npu` + IOMMU `okay`.
- Driver version is compiled in from `drivers/rknpu/include/rknpu_drv.h`
  (`DRIVER_MAJOR/MINOR/PATCHLEVEL`); the backport bumps PATCHLEVEL 7 → 8.

## Expected state on the flashed image

```bash
sudo cat /sys/kernel/debug/rknpu/version     # → RKNPU driver: v0.9.8
dmesg | grep -i rknpu                        # probe line, version, IOMMU attach
ls /sys/class/devfreq/ff300000.npu           # devfreq present
cat /sys/kernel/debug/rknpu/load             # load interface (see open question in 06)
```

Decision record: **D008** in `../DECISIONS.md` (including its 2026-07-04
provenance update).
