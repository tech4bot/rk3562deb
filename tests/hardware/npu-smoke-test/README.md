# NPU smoke test kit — hardware test matrix rows 17 (RKNN) and 18 (RKLLM)

Self-contained kit to prove the NPU works on a candidate image. Everything the
tablet needs is in this directory (plus the two runtime debs in `../../..//debs/`).

## Contents

| File | What |
|---|---|
| `mobilenet_v2_rk3562.rknn` | MobileNetV2 (fp16, no quantization) converted for rk3562 — from `onnx/models` mobilenetv2-12.onnx |
| `convert_mobilenet.py` | The exact conversion script that produced it (runs on Conrad in the rknn venv) |
| `conversion-env-pins.txt` | Working Conrad venv pins (see gotchas below) |
| `rknn_toolkit_lite2-2.3.2-cp311-*.whl` | Device-side Python inference wheel (Bookworm = Python 3.11) |
| `npu_smoke_test.py` | Loads the model, inits runtime, times 50 inferences |
| `run-smoke-test.sh` | Row-17-only orchestrator (original stock-eMMC flow); evidence to `./evidence/<timestamp>/` |
| `qwen3_0.6b_w4a16_g64_rk3562.rkllm` | Qwen3-0.6B w4a16_g64 for RKLLM row 18 (751 MiB, **gitignored** — regenerate via `scripts/convert-rkllm-model.sh Qwen/Qwen3-0.6B w4a16_g64`) |
| `deploy-to-candidate.sh` | **Conrad-side**: push debs + models + runner to the tablet, install, verify (idempotent) |
| `run-candidate-smoke.sh` | **On-device**: rows 17 + 18 in one pass, evidence to `~/validation/row-1{7,8}-*.txt` (session-001 convention) |

## Candidate image (SD-boot) procedure — session-001, rows 17–18

This is the flow for a **freshly flashed candidate image** (vendor 6.1.75,
rknpu 0.9.8 backport + DT enable baked in). It is distinct from the
stock-eMMC run below: the candidate rootfs is fresh, so nothing staged on the
stock system (e.g. the old `~/rkllm-smoke/` model on the eMMC) exists after SD
boot — everything is re-deployed from Conrad.

```bash
# 1. On Conrad, from this directory. IP is DHCP and may have changed after
#    SD boot — check the router/serial console first.
./deploy-to-candidate.sh <tablet-ip>          # copies ~760 MiB on first run;
                                              # re-runs skip unchanged files

# 2. On the tablet:
ssh frodo@<tablet-ip>
~/npu-smoke-test/run-candidate-smoke.sh

# 3. Back on Conrad, collect evidence for the session log:
scp 'frodo@<tablet-ip>:validation/row-1*.txt' ../session-001/
```

Row 17 = driver probe (`/sys/kernel/debug/rknpu/version` → v0.9.8, devfreq
node present) + librknnrt 2.3.2 + 50 MobileNetV2 inferences via rknnlite.
If rknnlite can't be installed (no device network for `python3-pip`/deps),
the row degrades to driver-probe + library-presence and reports **PARTIAL**,
not PASS.

Row 18 = `llm_demo` (from `librkllmrt_1.3.0-2_arm64.deb`) with the Qwen3
model and a fixed prompt. PASS requires exit 0, the exact banner
`rkllm-runtime version: 1.3.0, rknpu driver version: 0.9.8, platform: RK3562`,
no driver-too-low warning, and non-empty generated text. The runner sets
`RKLLM_LOG_LEVEL=1` so librkllmrt prints its Prefill/Generate perf table —
the extracted tokens/s in `row-18-perf-*.txt` is the stack's **first perf
datapoint** (the 2026-07-05 stock run didn't capture it). Clocks are pinned
via `/usr/share/rkllm-demo/fix_freq_rk3562.sh` first (persists until reboot;
`SKIP_FIXFREQ=1` to skip). Rows are isolated: a row-17 failure does not
block row 18.

Notes:
- The model is staged under `~` on the device — never `/tmp`, which is a
  512 MiB tmpfs and cannot hold the 751 MiB `.rkllm`.
- Prompt/token budget overridable: `RKLLM_PROMPT`, `RKLLM_MAX_NEW` (default
  256 — Qwen3 emits a `<think>` block before the answer), `RKLLM_MAX_CTX`.
- Version contract reminder: driver 0.9.8 ↔ librknnrt 2.3.2 ↔ librkllmrt
  1.3.0. A wrong banner or a "driver too low" warning means the image's
  rknpu backport (wiki 03) didn't land — that's a kernel-layer problem, not
  a userspace one.

## Stock-eMMC run (original row-17 flow, kept for reference)

This is how row 17 tooling was exercised on the **stock eMMC system**
(precedent only — stock results do not close matrix rows for the candidate
image). Manual setup, evidence to `./evidence/<timestamp>/`:

```bash
# one-time setup (librknnrt deb is in ../../..//debs/)
sudo apt install ./librknnrt_2.3.2-1_arm64.deb
pip3 install --break-system-packages ./rknn_toolkit_lite2-2.3.2-cp311-*.whl

# run (captures driver version, devfreq, load before/during/after, timings)
./run-smoke-test.sh
```

PASS = runtime initializes and 50 inferences complete. The script also
captures `/sys/kernel/debug/rknpu/load` idle vs. mid-run, answering the
"is NPU load reporting live or static?" question (wiki 06, open question 1).

## Rebuilding the model on Conrad

```bash
source ~/venvs/rknn/bin/activate   # created per scripts/setup-rknn-conversion-env.sh
python convert_mobilenet.py        # needs mobilenetv2-12.onnx alongside
```

### Conversion-environment gotchas (hit and solved 2026-07-04)

- `setuptools<81` required — v81 removed `pkg_resources`, which
  rknn-toolkit2 2.3.2 imports at startup.
- `onnx==1.16.1` — newer onnx removed `onnx.mapping`, which the toolkit uses.
  (Rockchip's own `requirements_cp312-2.3.2.txt` says `onnx>=1.16.1`; treat it
  as `==1.16.1`.)
- The ONNX zoo model has a dynamic batch dim: pass
  `inputs=['input'], input_size_list=[[1,3,224,224]]` to `load_onnx`.
- fp16 (`do_quantization=False`) is deliberate for the smoke test — no
  calibration dataset needed. Real workloads should use INT8 (wiki 05).
