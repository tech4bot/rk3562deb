# Samwise NPU / Image-Build Wiki

Working documentation for the `samwise` RK3562 tablet platform: how the image is
built on Conrad, how the NPU was brought up, how to validate on hardware, and
where the platform can go next. Everything here was verified against the real
repos, artifacts, and the physical device unless explicitly marked *future*.

| Page | Contents |
|---|---|
| [01 — Hardware & Software Baseline](01-hardware-baseline.md) | The tablet, the SoC, the stock software stack, captured provenance |
| [02 — Build Pipeline on Conrad](02-build-pipeline.md) | Repo layout, kernel pin, every build command, artifact locations |
| [03 — NPU Enablement](03-npu-enablement.md) | The disabled-DT bug, both patches, evidence trail, verification commands |
| [04 — Device Validation & Flashing](04-device-validation.md) | Safe flashing, provenance capture, hardware test matrix procedure |
| [05 — NPU Development Workflow](05-npu-workflow.md) | Model conversion on Conrad, native inference APIs on samwise, RKLLM |
| [06 — Future Options & Open Questions](06-future-options.md) | Mainline driver status, Track B, runtime packaging, open items |

Related documents outside this wiki:

- `../DECISIONS.md` — numbered decision log (D001–D009); D008 covers the NPU stack, D009 the ggml/llama.cpp deferral
- `../HARDWARE_TEST_MATRIX.md` — the 20-row acceptance matrix; NPU is rows 17–18
- `../ARCHITECTURE.md` — layered repo architecture (upstream / overlay / evidence / tooling)
- `../../baseline/current-system/` — evidence captured from the stock device
- `~/repos/ArmbianBuild/armbian_in.md` — full platform specification
- `~/repos/ArmbianBuild/rm_tablet.md` — rk-tui terminal dashboard specification

## One-paragraph project summary

`samwise` is a Doogee U10-class RK3562 tablet running Debian 12 Bookworm. The
project builds a reproducible, recovery-safe Armbian-based microSD image for it
on `Conrad` (WSL2 Ubuntu 24.04, x86_64), preserving all stock hardware behavior
(Track A) before any modernization (Track B). The NPU is served exclusively by
the Rockchip vendor stack — in-kernel `rknpu` driver + `librknnrt` userspace —
which is the only production-viable path for RK3562 and therefore pins Track A
to the vendor 6.1 kernel (see D008).
