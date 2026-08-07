#!/usr/bin/env bash
# graft-bootloader.sh — write the proven idbloader + u-boot.itb onto an
# already-flashed candidate SD card (or into a .img file).
#
# Why: the Armbian candidate image ships with BOOTCONFIG="none" (no
# bootloader), so the RK3562 Boot ROM never selects the SD card. See
# loader/README.md for provenance of the blobs.
#
# Usage:
#   sudo ./graft-bootloader.sh /dev/sdX        # graft onto a flashed SD card
#   ./graft-bootloader.sh some-image.img       # graft into an image file
#
# Safety: refuses mmcblk2 (tablet eMMC), the disk hosting /, and any target
# whose partition 1 does not start at sector 32768 (16 MiB) — the layout that
# leaves the 32 KiB–16 MiB loader gap free.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IDB="$SCRIPT_DIR/loader/idbloader.img"
ITB="$SCRIPT_DIR/loader/u-boot.itb"
IDB_SHA="09284d83f97c7706190b5c176fcbe032eecdfbc1896d1755039fc1bdae9f9718"
ITB_SHA="a436414ca8b572fd338608d548ac2c03ac60da5e8f4479cc1c39c8ea289fd10b"

die() { echo "ERROR: $*" >&2; exit 1; }

TARGET="${1:-}"
[[ -n "$TARGET" ]] || die "usage: $0 </dev/sdX | image.img>"

[[ -f "$IDB" && -f "$ITB" ]] || die "loader blobs missing under $SCRIPT_DIR/loader/"
echo "Verifying loader blob integrity..."
echo "$IDB_SHA  $IDB" | sha256sum --check --quiet || die "idbloader.img sha256 mismatch"
echo "$ITB_SHA  $ITB" | sha256sum --check --quiet || die "u-boot.itb sha256 mismatch"

if [[ -b "$TARGET" ]]; then
    # --- block device safety rails (D002/D004) ---
    [[ "$TARGET" == *mmcblk2* ]] && die "target is the tablet eMMC naming — never write eMMC"
    ROOT_DISK="$(lsblk -no PKNAME "$(findmnt -no SOURCE /)" 2>/dev/null || true)"
    [[ -n "$ROOT_DISK" && "$TARGET" == "/dev/$ROOT_DISK" ]] && die "target hosts the running rootfs"
    [[ "$TARGET" =~ [0-9]$ && "$TARGET" == /dev/sd* ]] && die "target looks like a partition; pass the whole disk (e.g. /dev/sdb)"
    [[ $EUID -eq 0 ]] || die "block-device mode needs root (sudo)"
elif [[ -f "$TARGET" ]]; then
    :
else
    die "target $TARGET is neither a block device nor a file"
fi

# --- layout check: partition 1 must start at sector 32768 ---
P1_START="$(fdisk -l "$TARGET" 2>/dev/null | awk '$1 ~ /1$/ && $2 ~ /^[0-9]+$/ {print $2; exit}')"
[[ "$P1_START" == "32768" ]] || die "partition 1 starts at sector '${P1_START:-unknown}', expected 32768 — is this the candidate layout?"

# --- preview what is at the loader offsets now ---
echo "Current bytes at 32 KiB and 8 MiB (expect zeros on an unpatched candidate):"
xxd -l 16 -s 32768 "$TARGET"
xxd -l 16 -s $((8*1024*1024)) "$TARGET"

echo
read -r -p "Write loaders to $TARGET? [yes/NO] " ANSWER
[[ "$ANSWER" == "yes" ]] || die "aborted by user"

dd if="$IDB" of="$TARGET" bs=512 seek=64 conv=fsync,notrunc status=none
dd if="$ITB" of="$TARGET" bs=512 seek=16384 conv=fsync,notrunc status=none
sync

echo "Verifying signatures on target..."
IDB_MAGIC="$(xxd -p -l 4 -s 32768 "$TARGET")"
ITB_MAGIC="$(xxd -p -l 4 -s $((8*1024*1024)) "$TARGET")"
[[ "$IDB_MAGIC" == "4c445220" ]] || die "idbloader magic not found after write (got '$IDB_MAGIC', want 4c445220 'LDR ')"
[[ "$ITB_MAGIC" == "d00dfeed" ]] || die "FIT magic not found after write (got '$ITB_MAGIC')"

echo "OK: idbloader ('LDR ') at 32 KiB, u-boot FIT (d00dfeed) at 8 MiB."
echo "Eject the card, insert into the tablet, and power on."
