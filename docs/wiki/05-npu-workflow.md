# 05 — NPU Development Workflow

The native-use pipeline once the image is validated: models are converted on
Conrad (x86), inference runs on samwise (ARM64, NPU). The RK3562's unit is
1 TOPS INT8 — quantized INT8 models are the intended payload.

## The stack, top to bottom

| Layer | Component | Where |
|---|---|---|
| Model conversion | `rknn-toolkit2` (Python, x86_64 only) | Conrad |
| Inference API (C/C++) | `librknnrt.so` — version **2.3.2** proven on this device | samwise |
| Inference API (Python) | `rknn-toolkit-lite2` (wraps librknnrt) | samwise |
| LLM runtime | RKLLM (`librkllmrt`) **1.3.0**, packaged; needs driver ≥ 0.9.8 (on-device confirmed) | samwise |
| Kernel driver | `rknpu` v0.9.8 (in-kernel, CONFIG_ROCKCHIP_RKNPU=y) | image |
| Hardware | `npu@ff300000` + IOMMU + `vdd_npu` rail | tablet |

Upstream sources: [airockchip/rknn-toolkit2](https://github.com/airockchip/rknn-toolkit2)
(toolkit, runtime binaries, C API headers, examples) and
[airockchip/rknn-llm](https://github.com/airockchip/rknn-llm) (RKLLM).
RK3562 is a supported target platform in both.

## Conversion on Conrad (typical flow)

```python
# pip install rknn-toolkit2  (x86_64 Linux; match the runtime's 2.3.x series)
from rknn.api import RKNN

rknn = RKNN()
rknn.config(target_platform='rk3562',
            mean_values=[[123.675, 116.28, 103.53]],
            std_values=[[58.395, 57.12, 57.375]])
rknn.load_onnx(model='model.onnx')            # also: load_tflite, load_pytorch
rknn.build(do_quantization=True, dataset='calib_images.txt')  # INT8 + calibration set
rknn.export_rknn('model.rknn')
```

Keep the toolkit's minor version aligned with the device runtime (2.3.x ↔
librknnrt 2.3.2). A model built by a much newer toolkit may demand a newer
runtime, which in turn can demand a newer kernel driver — the same version
contract that drove the 0.9.8 backport.

The toolkit also offers a **simulator** and, with the device connected/
reachable, on-target accuracy analysis and performance evaluation
(`rknn.eval_perf()`), useful before committing to a model.

## Inference on samwise

C API sketch (link `-lrknnrt`, headers from the rknn-toolkit2 repo):

```c
rknn_context ctx;
rknn_init(&ctx, model_data, model_size, 0, NULL);
rknn_inputs_set(ctx, io_num.n_input, inputs);
rknn_run(ctx, NULL);
rknn_outputs_get(ctx, io_num.n_output, outputs, NULL);
```

Python:

```python
from rknnlite.api import RKNNLite
rl = RKNNLite()
rl.load_rknn('model.rknn')
rl.init_runtime()
outputs = rl.inference(inputs=[img])
```

Validation runs should double as matrix row 17 evidence: capture the sample's
stdout and `sudo cat /sys/kernel/debug/rknpu/load` during inference.

## RKLLM

Small quantized LLMs, run on device with `librkllmrt` + the `llm_demo`
binary. RK3562 has been a supported RKLLM target since upstream
release-v1.2.0; the current pin is **v1.3.0** (2026-06-17), which requires
kernel driver **≥ 0.9.8** — the same version the D008 backport provides. This
is matrix row 18.

### Conversion on Conrad

```bash
scripts/setup-rkllm-conversion-env.sh          # once: venv at ~/venvs/rkllm
scripts/convert-rkllm-model.sh Qwen/Qwen3-0.6B w4a16_g64
# -> tests/hardware/npu-smoke-test/qwen3_0.6b_w4a16_g64_rk3562.rkllm
```

`setup-rkllm-conversion-env.sh` builds a CPU-only environment (torch 2.6.0
CPU wheels, `auto_gptq` built from sdist — no cp312 wheel exists) around the
`rkllm-toolkit` 1.3.0 wheel; `convert-rkllm-model.sh` wraps
`convert_rkllm_model.py`, which downloads the HF model if needed and calls
`rkllm.build()` with the RK3562-only quant types enforced by `argparse`
(below). Converting Qwen3-0.6B to `w4a16_g64` took roughly 10 minutes on
Conrad's CPU and produced a 751 MiB `.rkllm` (dominated by the fp16
embedding/tokenizer tables, which w4a16 does not quantize). `.rkllm` outputs
are gitignored — regenerate them locally, don't commit them.

RK3562 quant types, per `Rockchip_RKLLM_SDK_EN_1.3.0.pdf` Table 3-3 (single
NPU core only — `num_npu_core` must be 1):

| `quantized_dtype` | Notes |
|---|---|
| `w8a8` | 8-bit weights and activations |
| `w4a16_g32` / `w4a16_g64` / `w4a16_g128` | 4-bit weights, fp16 activations, grouped by the given size; activations aren't quantized so no calibration dataset is required |
| `w4a8_g32` | 4-bit weights, 8-bit activations, grouped |

(`w4a16` with no group and `w8a8_g*` are valid on other targets — RK3576,
RV1126B, RK3588 — but rejected for `rk3562` by the conversion script.)

### Runtime packaging and on-device verification

`debs/librkllmrt_1.3.0-2_arm64.deb` ships `librkllmrt.so` 1.3.0, `rkllm.h`
(pinned to the same upstream tag — mixing tags across a re-package is an ABI
hazard), a source-built `llm_demo`, and `fix_freq_rk3562.sh`. `llm_demo` must
be cross-compiled against a **Debian 12 Bookworm arm64 sysroot**, not
Conrad's native Ubuntu 24.04 cross-toolchain sysroot — the first attempt
(`-1`, superseded) leaked `GLIBC_2.38`/`GLIBCXX_3.4.32` requirements into the
binary and failed to start on Bookworm target (`version 'GLIBC_2.38' not
found`); see the deb's own `/usr/share/doc/librkllmrt/README.samwise` and
DECISIONS.md D008 (2026-07-05 update) for the full root cause.

Verified 2026-07-05 on the **stock eMMC system** (driver 0.9.8, precedent
only — not yet run on a flashed candidate image, so this does not close
matrix row 18):

```
rkllm-runtime version: 1.3.0, rknpu driver version: 0.9.8, platform: RK3562
```

with no driver-too-low warning, followed by a correct end-to-end answer from
the converted Qwen3-0.6B model — the first LLM inference run on this
project's NPU stack. Token/s was not captured in this pass.

**Candidate (SD-boot) image procedure:** `tests/hardware/npu-smoke-test/`
now has a dedicated candidate-image flow, built for the session-001
validation kit (`../../tests/hardware/session-001/`) — as of 2026-07-12 it
has not yet been executed against hardware, so matrix rows 17 and 18 are
still open. On Conrad: `npu-smoke-test/deploy-to-candidate.sh <tablet-ip>`
pushes `librknnrt_2.3.2-1_arm64.deb`, `librkllmrt_1.3.0-2_arm64.deb`, the
Qwen3 `.rkllm`, the MobileNetV2 `.rknn`, and the rknnlite wheel to the
tablet's home directory (the SD-booted rootfs is fresh — nothing staged on
the stock eMMC system, like the old `~/rkllm-smoke/`, is present after SD
boot) and installs the debs. On the tablet:
`~/npu-smoke-test/run-candidate-smoke.sh` runs rows 17 and 18 isolated (a
row-17 failure never blocks row 18), with `RKLLM_LOG_LEVEL=1` set so
`librkllmrt` prints its Prefill/Generate perf table — the first tok/s
datapoint captured for this stack, once run. See
`tests/hardware/npu-smoke-test/README.md` for the full procedure, PASS
criteria, and gotchas (clock pinning, `<think>`-block token budget, etc.).

**Staging note:** samwise's `/tmp` is a 512 MiB tmpfs — a several-hundred-MB
`.rkllm` file will not fit. Stage converted models under `~` (home) on the
device, not `/tmp`.

## CPU fallback as correctness reference (D008)

Keep a CPU path (onnxruntime or XNNPACK-backed TFLite on the A53s) purely to
diff outputs against the NPU results when debugging quantization or runtime
issues. It is not a serving path — four A53s are no match for even 1 TOPS of
INT8 — and GPU (Mali-G52) inference is explicitly out of scope.

## Packaging the runtime, per spec `NPU_RUNTIME: opt-in, separately versioned`

The runtime ships as versioned opt-in debs in the overlay (`rk3562deb`
`debs/` dir feeding image customization), **not** baked into the base image:

- RKLLM deb: `debs/librkllmrt_1.3.0-2_arm64.deb` — `librkllmrt.so` +
  `rkllm.h` + source-built `llm_demo` + `fix_freq_rk3562.sh`, as described
  above. **Exists and is on-device verified** (stock system, 2026-07-05); the
  "copy the stock `.so` onto a candidate image" workaround is now obsolete
  for RKLLM.
- `librknnrt` deb: `debs/librknnrt_2.3.2-1_arm64.deb` — `librknnrt.so` 2.3.2
  (binary from `airockchip/rknn-toolkit2` tag v2.3.2; version string matches
  the 2026-07-04 stock-device capture) plus the `rknn/` C headers. **Exists**;
  the "copy the stock `.so` onto a candidate image" workaround is now obsolete
  for RKNN too. Not yet run on a flashed candidate image — matrix row 17
  stays open; `tests/hardware/npu-smoke-test/` is the self-contained kit
  (MobileNetV2 fp16 model, conversion script, device wheel, smoke-test
  runner) to close it.
