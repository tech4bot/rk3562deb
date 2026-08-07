# session-001 — first on-device validation of the samwise candidate image

This is the runbook for the **first** boot of an Armbian candidate image on
the samwise tablet. As of writing this, the tablet has never booted a
candidate image — it has only run the stock vendor system (captured in
`baseline/current-system/`).

Candidate under test (CLI image; the `_xfce_desktop` variant is a later
session):

```
/home/frodo/repos/ArmbianBuild/output/images/Armbian-unofficial_24.11.0-trunk_Doogee-u10_bookworm_vendor_6.1.75-sdboot.img
```

- **Flash the `-sdboot` variant, not the raw build output.** The raw Armbian
  image ships with no bootloader (`BOOTCONFIG="none"`; first boot attempt
  2026-07-14 fell into the eMMC's Android Recovery). The `-sdboot` variants
  are byte-identical copies with the proven idbloader + u-boot.itb grafted
  in via `graft-bootloader.sh` (provenance in `loader/README.md`).
- Kernel: 6.1.75 (vendor), built 2026-07-04
- NPU DT-enable + rknpu 0.9.8 backport confirmed baked in (see
  `docs/wiki/03-npu-enablement.md`)
- sha256 (CLI `-sdboot`, 2026-07-14):
  `4c8dc125c0583e0b445c0395d7771644436cfb6103dcae3b3956ac18d0597587`
  — a proper checkable sidecar exists: `sha256sum --check
  sdboot-images.sha256` in the images dir covers both `-sdboot` variants
  (XFCE `-sdboot`: `dfadcfb7…cdd7c405`). The raw build's own `.sha` sidecar
  is still broken (embeds the build's `.tmp/` path); raw CLI image hash for
  reference: `6055717db7f00e8bd08b9c7e5e7b567b59bc3fcdec34f286a65931a3a5a1a3b6`

No `manifests/images/*.json` manifest exists yet for this build (that
directory is currently empty). Until one exists, `flash-image-safely.sh
--manifest` verification is unavailable for this image — use the manual
sha256 compare below instead. `--skip-verify` is not needed since we're not
passing `--manifest` in the first place.

## Safety rails — read before touching anything (D002/D004)

- **Never write to `/dev/mmcblk2`.** That is the tablet's eMMC, holding the
  vendor Android install. `scripts/flash-image-safely.sh` hard-rejects
  `mmcblk2*` targets and anything sized 100–130 GiB (the known eMMC size
  band) as a second guard, but the operator is still the last line of
  defense — **triple-check `lsblk` output before confirming any flash.**
- Candidate images boot from **external microSD only**.
- Keep the current known-good microSD (or whatever card was in the tablet
  before this session) intact as the rollback path. Rollback = swap the
  card back, no reflashing required.
- This session's scripts (`capture-matrix.sh`, `run-remote.sh`) never flash
  anything and never touch block devices — they only run read-mostly
  sysfs/procfs probes over SSH and copy small text evidence files. The one
  exception is a single ~10 MiB throwaway `dd` write for the storage test
  (row 14), written under `~/validation/...` on the candidate's own SD
  rootfs and deleted immediately after — never to `/dev/mmcblk2` or any raw
  block device.

## 1. Pre-flight (on Conrad, before touching the tablet)

```bash
cd ~/repos/rk3562deb

IMG=~/repos/ArmbianBuild/output/images/Armbian-unofficial_24.11.0-trunk_Doogee-u10_bookworm_vendor_6.1.75-sdboot.img

# 1a. Confirm the image's actual hash (the -sdboot sidecar is checkable):
(cd "$(dirname "$IMG")" && sha256sum --check sdboot-images.sha256)
# expect: ...-sdboot.img: OK (both variants)

# 1b. Insert the target microSD card into Conrad and identify it.
#     TRIPLE-CHECK this is the SD card and not any other disk on Conrad.
lsblk
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,MODEL,SERIAL
#   - Confirm SIZE matches your physical SD card, not a 100-130 GiB range
#     (that range is blocked by the flash script as a suspected-eMMC guard
#     anyway, but don't rely on the guard — read the output yourself).
#   - Confirm MODEL/SERIAL looks like a card reader, not an internal disk.

# 1c. Flash with the guarded helper (preferred). Replace /dev/sdX with the
#     device YOU confirmed in 1b — never guess, never reuse a value from an
#     earlier session without re-checking lsblk.
~/repos/rk3562deb/scripts/flash-image-safely.sh \
  --image "$IMG" \
  --target /dev/sdX
#   The script will print device details, warn if the target doesn't look
#   removable/USB, and require you to type "yes-flash" to proceed. It hard-
#   rejects any target matching mmcblk2 or the 100-130 GiB eMMC size band.
```

If `flash-image-safely.sh` is ever missing or its interface changes, do NOT
improvise — stop and re-verify against `docs/wiki/04-device-validation.md`'s
manual fallback (`sha256sum --check` + `dd ... conv=fsync`), and re-confirm
the target device by hand before running it. As of this session the script
exists and behaves as described above.

## 2. Boot procedure

1. Safely eject the freshly-flashed SD card from Conrad.
2. Power off the tablet fully (don't just screen-lock it).
3. Insert the SD card into the tablet.
4. Power on and **watch the screen** — this is the only time you can attest
   "reached login without manual recovery" for matrix row 1.
5. Expect: Armbian first-boot sequence, eventually a login prompt (this is a
   CLI image, no desktop).
6. Find the tablet's IP address (DHCP — it will very likely differ from any
   previous session): check your router/DHCP leases, or if you have a
   monitor/keyboard on the tablet, `ip -4 addr show` locally.

### If boot goes dark

Serial console: **ttyS0 @ 1500000 baud**. Connect a USB-serial adapter to
the tablet's debug UART pins and use your preferred terminal program (e.g.
`screen /dev/ttyUSBx 1500000` or `minicom -D /dev/ttyUSBx -b 1500000`) from
Conrad or another host with the adapter attached. The kernel cmdline routes
early console output there, so you should see U-Boot and kernel boot
messages even if the DSI panel never lights up.

If you needed the serial console to recover (e.g. to fix a boot argument or
confirm what hung), row 1 in the matrix is **not** a clean PASS — record
that a manual recovery was needed, even if you got a shell afterward.

Rollback if the candidate doesn't boot at all: power off, remove the
candidate SD card, reinsert the previous known-good card. No re-flash
needed.

## 3. Run the capture

From Conrad, once you have the tablet's IP:

```bash
cd ~/repos/rk3562deb/tests/hardware/session-001
./run-remote.sh --host 192.168.11.167
# or, if the user differs from frodo:
# ./run-remote.sh --host 192.168.11.167 --user someone
```

This will:
1. Check SSH connectivity (fails fast with a clear message if the tablet
   isn't reachable yet — give first boot a minute or two).
2. Copy `capture-matrix.sh` to the tablet's home directory.
3. Run it there. It captures evidence for all 20 matrix rows into
   `~/validation/session-001-<timestamp>/` **on the tablet** (never `/tmp`
   — that's a 512 MiB tmpfs on this image and must not be used for
   evidence capture, per the on-device storage constraints).
4. Pull that directory back to
   `tests/hardware/session-001/evidence/session-001-<timestamp>/` on
   Conrad.
5. Print `summary.txt` (one line per row: verdict + evidence file name).

`capture-matrix.sh` can also be run directly on the tablet if you already
have a shell there (e.g. via a direct SSH session Conrad can't establish):

```bash
scp ~/repos/rk3562deb/tests/hardware/session-001/capture-matrix.sh frodo@<ip>:~/
ssh frodo@<ip> '~/capture-matrix.sh'
```

Then copy `~/validation/session-001-*/` back by hand into
`tests/hardware/session-001/evidence/`.

## 4. What the capture does and doesn't cover

Each row writes `row-NN-<slug>.txt` with raw command output and a final
`VERDICT: PASS|FAIL|MANUAL|SKIP - reason` line, auto-collected into
`summary.txt`.

- **PASS/FAIL** — machine-checkable rows (e.g. row 2 root filesystem source
  must be `mmcblk0*`, never `mmcblk2*`; row 20 dmesg scan with a
  repeated-failure heuristic).
- **MANUAL** — rows needing a human to look at the screen, touch it, listen
  for audio, or observe over a time window (display content, touch feel,
  suspend-window). These have strong automatic evidence attached but are
  not closed out by the script alone.
- **SKIP** — row 19 (dashboard). Per `docs/wiki/06-future-options.md`, the
  rk-tui dashboard and its hardware collectors don't exist on any image yet
  (future work) — there is nothing on this candidate to check.

### Rows 17–18 (NPU / RKLLM) — do not duplicate the dedicated kit

`capture-matrix.sh` only probes driver version, devfreq binding, and
runtime-library presence for rows 17 and 18 — it deliberately does **not**
run inference. The actual PASS/FAIL for those rows, including the
before/during-inference NPU load comparison that answers
`docs/wiki/06-future-options.md` open question #1 ("is
`/sys/kernel/debug/rknpu/load` live or static?"), is owned by
`tests/hardware/npu-smoke-test/`:

```bash
scp -r ~/repos/rk3562deb/tests/hardware/npu-smoke-test frodo@<ip>:~/npu-smoke-test
ssh frodo@<ip>
  cd ~/npu-smoke-test
  sudo apt install ./librknnrt_2.3.2-1_arm64.deb   # one-time
  pip3 install --break-system-packages ./rknn_toolkit_lite2-2.3.2-cp311-*.whl
  ./run-smoke-test.sh
```

That kit's own evidence directory (`npu-smoke-test/evidence/<timestamp>/`)
is the record for rows 17–18 — reference it, don't recreate it here.

### Known discrepancy: row 14 (storage) as literally specified

The matrix's literal command is `dd if=/dev/zero of=/tmp/test bs=1M
count=10`. On this image `/tmp` is a 512 MiB tmpfs (RAM-backed), so that
command tests RAM, not the SD card, even though the row is titled "microSD
I/O". `capture-matrix.sh` runs the literal `/tmp` command for compliance
(bounded to 10 MiB, safe for the tmpfs) **and** an equivalent write against
the real SD-backed rootfs (inside the evidence directory itself) to
actually exercise storage I/O, then greps dmesg for mmc/ext4 errors. The
row's auto-grade is based on the real SD-backed write, not the tmpfs one.
Flag this to whoever owns the matrix if the wording should be corrected
upstream.

## 5. Recording results

Per `docs/HARDWARE_TEST_MATRIX.md`, each promoted image needs: date, image
manifest reference, captured output paths, and pass/fail per row. This
session's evidence covers the "captured output paths" and machine-gradable
"pass/fail" parts. For the full record:

1. Note the date, the image path/sha above, and
   `tests/hardware/session-001/evidence/session-001-<timestamp>/summary.txt`
   as the evidence path.
2. Close out every MANUAL row by hand and update its verdict.
3. Fold in the NPU kit's result for rows 17–18.
4. Cross-check against the regression baseline:
   ```bash
   python3 ~/repos/rk3562deb/scripts/compare-baselines.py \
     --baseline ~/repos/rk3562deb/baseline/current-system \
     --candidate <a collect-target-test-report.sh capture, not this one> \
     --output comparison-report.json --human comparison-report.txt
   ```
   `compare-baselines.py` expects the file layout produced by
   `capture-samwise-baseline.sh` (via `collect-target-test-report.sh
   --host frodo@<ip>`), which differs from this matrix-oriented capture. If
   you want an automated baseline diff (not just the 20-row matrix), run
   `scripts/collect-target-test-report.sh --host frodo@<ip>` separately —
   it captures the baseline-shaped snapshot and runs the comparison for
   you.
5. Per project spec: an image that boots but has **lost** a P0/P1
   capability present in the baseline is a regression and **fails** the
   image, even if most rows are green. P0 rows: Boot, Root, SSH, Wi-Fi,
   Display, Touch, Power, Storage (rows 1, 2, 3, 4, 5, 7, 8, 14).
6. Updating `docs/HARDWARE_TEST_MATRIX.md` itself and `docs/DECISIONS.md`
   is out of scope for this kit — that's the scribe's job, not something
   these scripts do automatically.

## Files in this directory

| File | What |
|---|---|
| `README.md` | This runbook |
| `capture-matrix.sh` | Runs on the booted candidate; captures all 20 rows into `~/validation/session-001-<ts>/` |
| `run-remote.sh` | Runs on Conrad; scp's the capture script over, runs it, pulls evidence back |
| `evidence/` | Populated by `run-remote.sh`; gitignored (see `.gitignore` in this directory) — pulled evidence can include full dmesg dumps and is treated as disposable/regenerable, not committed |
