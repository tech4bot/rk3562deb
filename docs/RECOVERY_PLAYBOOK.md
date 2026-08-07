# Recovery Playbook — Samwise

## Purpose

This document defines the recovery procedures for the samwise tablet when a candidate image fails to boot or causes a regression.

## Prerequisites

Before testing ANY candidate image:

1. **Known-good microSD card** is retained unmodified and labeled
2. **Full image backup** exists on Conrad with verified SHA-256 checksum
3. **SSH access** to the known-good system is verified from Conrad
4. **Known-good boot artifacts** (kernel, DTB, extlinux.conf) are copied to baseline/

## Recovery Procedures

### R1: Candidate image does not boot (F2)

**Symptoms:** Black screen, boot loop, no SSH access after 3 minutes.

**Steps:**
1. Power off the tablet (hold power 10+ seconds)
2. Remove the candidate microSD card
3. Insert the known-good microSD card
4. Power on — the tablet should boot to the known-good system
5. Verify SSH access from Conrad: `ssh frodo@samwise`
6. Collect any available boot evidence from the candidate card if possible
7. Record the failure in the test report with image manifest reference

### R2: Candidate boots but hardware regression (F3/F4)

**Symptoms:** Login works but display, touch, Wi-Fi, or other hardware is non-functional.

**Steps:**
1. Collect the test report: `./scripts/collect-target-test-report.sh --host frodo@samwise`
2. Power off
3. Swap to known-good card
4. Boot and verify known-good functionality
5. Classify the regression (F3 = platform, F4 = capability)
6. Do not promote the candidate image

### R3: Accidental eMMC write (F5)

**Symptoms:** Any evidence of writes to /dev/mmcblk2.

**Steps:**
1. **STOP ALL WORK IMMEDIATELY**
2. Document the exact state:
   - What command was run
   - What was written
   - Current partition table: `lsblk /dev/mmcblk2`
   - Any dmesg output related to mmcblk2
3. Do NOT attempt to "fix" the eMMC
4. Boot from known-good microSD
5. Assess whether Android boot is still functional (remove SD card, boot)
6. Record the incident in DECISIONS.md

### R4: Build host failure (F0)

**Steps:**
1. Preserve build logs from artifacts/
2. Check host-preflight.sh output
3. Verify disk space, RAM, container runtime
4. Check for WSL-specific issues (clock drift, filesystem mount)
5. Rebuild from clean worktree: `./scripts/build-image.sh --profile <name> --clean`

## Known-Good Image Verification

To verify the known-good backup:

```bash
# On Conrad, verify the stored image checksum
sha256sum <known-good-image.img.xz>
# Compare against baseline/checksums/known-good-image.sha256
```

## Emergency Contacts / Resources

- Known-good image location: [record path on Conrad]
- Backup location: [record secondary backup path]
- Known-good card label: [record physical label]
- Serial console access: [document if available]

## Failure Classification Reference

| Class | Definition | Severity |
|-------|-----------|----------|
| F0 | Build failure before artifact generation | Low (host issue) |
| F1 | Image fails to flash/verify | Low (artifact issue) |
| F2 | No boot / no SSH | Medium (boot issue) |
| F3 | Boot but platform hardware missing | High (regression) |
| F4 | Boot but accelerators/media/sensors missing | Medium (capability gap) |
| F5 | Any eMMC modification | Critical (stop work) |
