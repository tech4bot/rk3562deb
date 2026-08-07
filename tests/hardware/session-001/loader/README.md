# SD bootloader blobs (idbloader + u-boot.itb)

## Why these exist

The Armbian candidate image is built with `BOOTCONFIG="none"`, so it contains
**no bootloader**: offsets 32 KiB (idbloader) and 8 MiB (u-boot.itb) are zeros.
Without an idbloader signature at sector 64 the RK3562 Boot ROM ignores the SD
card and boots the eMMC vendor chain, which drops into **Android Recovery**
when the inserted SD confuses its boot scan (observed 2026-07-14, first
session-001 boot attempt).

The Armbian image's layout is otherwise compatible with the proven SD boot
chain documented in `docs/BOOT_CHAIN_DISCOVERY.md`: its FAT boot partition
starts at 16 MiB, leaving the 32 KiB–16 MiB gap free — exactly where these two
blobs belong. `graft-bootloader.sh` (one directory up) writes them in.

## Provenance

Extracted 2026-07-14 from the first 16 MiB of
`~/backups/samwise/samwise-microsd-20260607-181319.img.zst.partial` — the
2026-06-07 capture of the previously **working** SD-boot card built by the
upstream tech4bot/rk3562deb pipeline (`build.sh uboot`). Per
`docs/BOOT_CHAIN_DISCOVERY.md` this chain is: Firefly `rk356x/firefly-5.10`
U-Boot, ddr v1.06 (cea47a5df0), SPL v1.06, BL31 v1.22, BL32 v1.08. The
`.partial` suffix is irrelevant here: `dd` captures sequentially, so the first
16 MiB is complete and signature-verified (`LDR ` at 32 KiB, FIT `d00dfeed`
at 8 MiB).

| File | Region carved | Content size | sha256 |
|------|--------------|--------------|--------|
| `idbloader.img` | 32 KiB – 8 MiB | ~3.7 MB + zero pad | `09284d83f97c7706190b5c176fcbe032eecdfbc1896d1755039fc1bdae9f9718` |
| `u-boot.itb` | 8 MiB – 16 MiB | ~3.8 MB + zero pad | `a436414ca8b572fd338608d548ac2c03ac60da5e8f4479cc1c39c8ea289fd10b` |

Both files are full-region carves (padded with zeros to the region boundary),
so writing them also cleanly overwrites any stale loader data on a reused card.

## Proper fix (future)

Grafting is a session-unblock measure. The pipeline fix is to make the Armbian
build write these loaders into the image itself (userpatches hook or a proper
U-Boot artifact for this board) — tracked as a follow-up; see the wiki
build-pipeline page.
