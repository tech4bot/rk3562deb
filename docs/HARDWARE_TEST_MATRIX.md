# Hardware Acceptance Test Matrix — Samwise

## Overview

This matrix defines the minimum hardware validation for a `samwise` platform image.
Each row must be tested and recorded before an image can be promoted.

## Test Matrix

| # | Area | Test | Command / Method | Expected Result | Pass Condition | Status |
|---|------|------|-----------------|-----------------|----------------|--------|
| 1 | Boot | Cold boot from candidate microSD | Insert candidate SD, power on | System reaches login prompt | Login prompt without manual recovery | — |
| 2 | Root | Root filesystem identity | `findmnt /` | Shows candidate microSD partition | Root is candidate SD, never eMMC | — |
| 3 | SSH | Network login | `ssh frodo@samwise` from Conrad | Shell access | Connection succeeds | — |
| 4 | Wi-Fi | Join expected LAN | `iw dev wlan0 link` | Associated to AP | Interface stable, has IP address | — |
| 5 | Display | DSI panel | Observe display; `cat /sys/class/drm/card*/status` | Panel shows content | Correct resolution (800x1280), usable orientation, stable | — |
| 6 | Backlight | Brightness control | `cat /sys/class/backlight/*/brightness` and write test | Value changes, display responds | Read/write control works safely | — |
| 7 | Touch | GSL3673 input | `evtest /dev/input/eventN` | Touch events appear | Events map correctly after rotation | — |
| 8 | Power | Battery and charging | `cat /sys/class/power_supply/*/status` and `capacity` | Status and percentage | Values present and plausible | — |
| 9 | Suspend | No-suspend policy | Let system idle | System stays awake | No unexpected suspend during test window | — |
| 10 | IIO Sensor | DA223 / Mir3DA | `cat /sys/bus/iio/devices/*/name` | DA223/Mir3DA/SC7A20 visible | Device visible, valid axis readings | — |
| 11 | Thermal | Thermal zones | `cat /sys/class/thermal/thermal_zone*/temp` | Temperature values | Readings available, no thermal fault | — |
| 12 | Input | Power key, ADC keys | `cat /proc/bus/input/devices` | Expected devices listed | Power key, volume keys, headset present | — |
| 13 | Audio | ALSA devices | `aplay -l` | Sound devices listed | Enumerates, basic playback works | — |
| 14 | Storage | microSD I/O [^14] | `dd if=/dev/zero of=/tmp/test bs=1M count=10` | Write completes | Stable mounts, no eMMC writes in dmesg | — |
| 15 | GPU/DRM | Render device | `ls -la /dev/dri/` | DRI devices present | Expected DRM behavior | — |
| 16 | Media/RGA | Device nodes | `ls /dev/mpp_service /dev/rga` | Nodes exist | Test utility runs | — |
| 17 | NPU | RKNN sample | Run known-good inference test | Inference completes | Runtime initializes, result correct | — |
| 18 | RKLLM | Small model demo | Run llm_demo with test model | Output generated | Runtime initializes (where included) | — |
| 19 | Dashboard | Hardware monitor [^19] | Check existing dashboard collectors | Collectors report | No new critical failures | — |
| 20 | Logs | Error scan | `dmesg \| grep -iE 'error\|fail\|timeout'` | Review output | No repeated driver bind failures | — |

## Notes

[^14]: The literal command targets `/tmp`, which on the current candidate
image is a 512 MiB tmpfs (RAM-backed) — as written, this row exercises RAM,
not the SD card, despite its title. `tests/hardware/session-001/capture-matrix.sh`
runs the literal `/tmp` command for compliance (bounded to 10 MiB, safe for
the tmpfs) *and* an equivalent write against the real SD-backed rootfs, and
grades the row on the SD-backed result rather than the tmpfs one. This is a
methodology gap in the row as specified; flagged 2026-07-12, wording not yet
corrected here — do so if/when this row's command column is next touched.

[^19]: As of 2026-07-12 no dashboard/collector exists on any built image
(`rk-tui` is future work — see [wiki 06 — Future Options](wiki/06-future-options.md)).
Expect **SKIP** for this row until a collector exists to check.

## Classification

- **P0 (blocking):** Boot, Root, SSH, Wi-Fi, Display, Touch, Power, Storage
- **P1 (important):** Backlight, Suspend, Sensor, Thermal, Input, Audio, GPU/DRM
- **P2 (tracked):** Media/RGA, NPU, RKLLM, Dashboard, Logs

## Recording Results

For each test run, record:
1. Date and image manifest reference
2. Actual command output (capture file path)
3. Pass/Fail/Skip
4. Notes on any deviation from expected behavior

Results should reference the image manifest SHA and be stored alongside the test report.
