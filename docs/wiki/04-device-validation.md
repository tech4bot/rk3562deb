# 04 — Device Validation & Flashing

## Safety rails (non-negotiable, D002/D004)

- **Never write to `/dev/mmcblk2`** (the tablet's eMMC — it holds the vendor
  Android install; a bad write can brick the device). All project flash helpers
  hard-reject eMMC targets.
- Candidate images boot from **external microSD only** until the boot chain is
  fully documented.
- Keep the previous known-good microSD image (and `~/backups/samwise`) intact:
  rollback = swap cards.

## Flashing

Preferred: the guarded helper.

```bash
~/repos/rk3562deb/scripts/flash-image-safely.sh \
  --image ~/repos/ArmbianBuild/output/images/Armbian-unofficial_<ver>.img \
  --target /dev/sdX
```

Manual (only after triple-checking the target device with `lsblk`):

```bash
sha256sum --check <image>.sha
sudo dd if=<image>.img of=/dev/sdX bs=1M status=progress conv=fsync
```

Serial console is available at 1500000 baud (`ttyS0`) if boot goes dark;
the cmdline also puts early console output there.

## Post-boot validation, NPU-focused

Run on the booted candidate image. Capture output to files — the test matrix
requires recorded evidence, not a thumbs-up.

```bash
# 1. Identity: which kernel/DTB are we actually running?
uname -a                                   # expect 6.1.75-vendor-rk35xx
cat /proc/device-tree/model

# 2. Driver bound and at the right version
sudo cat /sys/kernel/debug/rknpu/version   # expect: RKNPU driver: v0.9.8
dmesg | grep -i rknpu                      # probe, no bind failures

# 3. Power/clock plumbing
ls /sys/class/devfreq/ff300000.npu
cat /sys/class/devfreq/ff300000.npu/{governor,cur_freq,available_frequencies}
grep -r vdd_npu /sys/kernel/debug/regulator/regulator_summary 2>/dev/null || \
  sudo cat /sys/kernel/debug/regulator/regulator_summary | grep -A1 vdd_npu

# 4. Runtime contract (after installing the runtime, see wiki 05)
#    run the known-good RKNN sample            → matrix row 17
#    run the RKLLM small-model demo            → matrix row 18

# 5. Load reporting (open question for rk-tui)
sudo cat /sys/kernel/debug/rknpu/load        # idle, then again under inference
```

Full sweep: the 20-row procedure in `../HARDWARE_TEST_MATRIX.md` (P0 boot/
display/touch/Wi-Fi rows first — an image that loses those is a regression
regardless of NPU state). `scripts/collect-target-test-report.sh --host
frodo@<tablet-ip>` automates capture and comparison against the baseline.

## Session-001 kit (full 20-row operator flow, automated)

`../../tests/hardware/session-001/` is the maintained runbook + automation
for a complete candidate-image validation pass — it doesn't replace the
safety rails above, it operationalizes the steps that follow them. End-to-end
operator flow:

1. **Flash.** Follow `session-001/README.md` section 1 (pre-flight): confirm
   the image's sha256 by eye, triple-check the target device with `lsblk`,
   then `scripts/flash-image-safely.sh`.
2. **Boot.** README section 2: watch the screen for a clean login (matrix row
   1), fall back to the ttyS0 @ 1500000 serial console if the display never
   lights up.
3. **Capture.** From Conrad, once the tablet has an IP:
   `session-001/run-remote.sh --host <tablet-ip>`. This copies
   `capture-matrix.sh` to the tablet, runs it there (all 20 matrix rows,
   each row isolated so one failure never aborts the rest, each ending in a
   `VERDICT: PASS|FAIL|MANUAL|SKIP` line), and pulls the evidence directory
   back to `session-001/evidence/session-001-<timestamp>/` on Conrad.
4. **NPU rows 17–18.** `capture-matrix.sh` only probes driver version,
   devfreq binding, and runtime-library presence for these rows — it
   deliberately does not run inference. Closing them is
   `../../tests/hardware/npu-smoke-test/`'s job: on a freshly-flashed
   candidate (SD-boot) image, `npu-smoke-test/deploy-to-candidate.sh
   <tablet-ip>` (Conrad-side; pushes both runtime debs, the Qwen3 model, the
   MobileNetV2 `.rknn`, and the rknnlite wheel — the SD-booted rootfs is
   fresh and has none of the stock system's staged files), then
   `~/npu-smoke-test/run-candidate-smoke.sh` on the tablet. See
   [05 — NPU Development Workflow](05-npu-workflow.md) for the stack details
   and `npu-smoke-test/README.md` for the full procedure.
5. **Fold into the record.** Close out MANUAL rows by hand, fold in the NPU
   kit's rows 17–18 result, cross-check against the baseline, and record
   final per-row verdicts in `../HARDWARE_TEST_MATRIX.md`. Neither kit
   writes to the matrix or `DECISIONS.md` itself — that's a manual step.

Two gotchas the first (session-001) run of this kit surfaced, worth knowing
before flashing any build produced the same way:

- The candidate image's `.img.sha` sidecar (as emitted by this build)
  records the build's `.tmp/` staging path, not the final output path, so
  `sha256sum --check <image>.sha` fails even when the hash itself is
  correct — compare the printed hash value by eye instead.
- `manifests/images/` is currently empty; no manifest exists yet for this
  build, so `flash-image-safely.sh --manifest` verification isn't available
  for it.

Evidence pulled back by `run-remote.sh` (and by the npu-smoke-test kit) is
gitignored and treated as disposable/regenerable — the permanent record of
a session's results is `../HARDWARE_TEST_MATRIX.md` itself, referencing the
evidence path and date.

## Recording results

Per the matrix: record date, image manifest reference, actual command output
(capture file path), and pass/fail per row. Compare against
`baseline/current-system/` with `scripts/compare-baselines.py`.

## Provenance capture from the *stock* system

Do this before replacing/retiring any stock install, from a direct SSH session
on the tablet (Conrad cannot resolve `samwise` — see wiki 02 gotchas):

```bash
~/repos/rk3562deb/scripts/capture-samwise-baseline.sh    # from a host with access
```

The 2026-07-04 capture that set the current version contract is documented in
[01 — Hardware & Software Baseline](01-hardware-baseline.md).
