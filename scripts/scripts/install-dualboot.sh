#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
#
# Review and (only on explicit confirmation) flash the Caihong Ubuntu 22.04
# installation set.
#
# This script is deliberately paranoid:
#   * it never runs by itself, and never flashes without --apply,
#   * it refuses any device whose fastboot product is not "caihong",
#   * it refuses a slot it was not told to use,
#   * it checks the root filesystem image against the real partition size,
#   * it prints the complete command sequence before doing anything,
#   * it erases only the dtbo partition of the slot being taken over,
#   * it never touches the partition table, and never writes to "userdata" in the
#     dual-boot variant.
#
# usage:
#   scripts/install-dualboot.sh --variant linux --slot b --list
#   scripts/install-dualboot.sh --variant linux --slot b            # dry run
#   scripts/install-dualboot.sh --variant linux --slot b --apply    # flash
#
# The dual-boot variant needs an existing GPT partition named "linux"; this
# script does not create or resize partitions. See docs/INSTALL.zh-CN.md.
set -Eeuo pipefail
CDPATH=

project_dir=$(cd -- "$(dirname -- "$0")/.." && pwd)
# shellcheck source=config/ubuntu.env
. "$project_dir/config/ubuntu.env"

release_dir=${RELEASE_DIR:-"$project_dir/release"}
variant=
slot=
apply=0
list_only=0
vbmeta=
assume_yes=0

usage()
{
	sed -n '2,26p' "$0"
	exit "$1"
}

die()
{
	printf 'error: %s\n' "$*" >&2
	exit 1
}

note()
{
	printf '%s\n' "$*"
}

while [ $# -gt 0 ]; do
	case $1 in
		--variant) variant=${2:?--variant needs a value}; shift 2 ;;
		--slot) slot=${2:?--slot needs a value}; shift 2 ;;
		--vbmeta) vbmeta=${2:?--vbmeta needs a file}; shift 2 ;;
		--apply) apply=1; shift ;;
		--list) list_only=1; shift ;;
		--yes) assume_yes=1; shift ;;
		-h|--help) usage 0 ;;
		*) echo "unknown option: $1" >&2; usage 2 ;;
	esac
done

case "$variant" in
	"$ROOTFS_LABEL_DUALBOOT"|"$ROOTFS_LABEL_SINGLE") ;;
	'') die "--variant is required (linux for dual boot, userdata for single system)" ;;
	*) die "--variant must be $ROOTFS_LABEL_DUALBOOT or $ROOTFS_LABEL_SINGLE" ;;
esac
case "$slot" in
	a|b) ;;
	'') die "--slot is required: which A/B slot will run Ubuntu?" ;;
	*) die "--slot must be a or b" ;;
esac

boot_image="$release_dir/caihong-ubuntu22.04-$UBUNTU_SUITE-boot-$variant.img"
rootfs_image="$release_dir/caihong-ubuntu22.04-rootfs-$variant.ext4.sparse.img"
[ -f "$boot_image" ] || die "missing boot image: $boot_image"
[ -f "$rootfs_image" ] || die "missing root filesystem image: $rootfs_image (decompress the released parts first)"
[ -f "$boot_image.sha256" ] || note "warning: no checksum file for $boot_image"
[ -f "$rootfs_image.sha256" ] || note "warning: no checksum file for $rootfs_image"

command -v python3 >/dev/null 2>&1 || die "python3 is required to read the sparse image header"

# Logical (unsparse) size, i.e. what the partition must be able to hold.
sparse_device=$(python3 - "$rootfs_image" <<'PY'
import struct, sys
with open(sys.argv[1], 'rb') as handle:
    head = handle.read(28)
magic, major, minor, file_hdr_sz, chunk_hdr_sz, blk_sz, total_blks, total_chunks, checksum = \
    struct.unpack('<IHHHHIIII', head)
if magic != 0xED26FF3A:
    sys.exit("not an Android sparse image")
print(total_blks * blk_sz)
PY
) || die "cannot read the sparse image header of $rootfs_image"
logical_bytes=$sparse_device

if [ "$list_only" = 1 ]; then
	note "release directory : $release_dir"
	note "boot image        : $(basename "$boot_image") ($(stat -c %s "$boot_image") bytes)"
	note "root filesystem   : $(basename "$rootfs_image") ($(stat -c %s "$rootfs_image") bytes on disk, $((logical_bytes / 1024 / 1024)) MiB logical)"
	note "variant           : $variant (root=PARTLABEL=$variant)"
	note "target slot       : $slot"
	note "vbmeta            : ${vbmeta:-not provided (Android Verified Boot must already be disabled)}"
	exit 0
fi

command -v fastboot >/dev/null 2>&1 || die "fastboot is not installed"
note "root filesystem logical size: $((logical_bytes / 1024 / 1024)) MiB"

note ""
note "== device =="
devices=$(fastboot devices 2>/dev/null | awk 'NF { print $1 }')
[ -n "$devices" ] || die "no device in fastboot mode; run 'adb reboot bootloader' first"
device_count=$(printf '%s\n' "$devices" | wc -l)
[ "$device_count" -eq 1 ] || die "more than one fastboot device is attached; disconnect the others"
serial=$devices
note "serial: $serial"

product=$(fastboot getvar product 2>&1 | awk -F': ' '/^product:/ { print $2 }' | head -n 1)
[ -n "$product" ] || die "cannot read the fastboot product; refusing to continue"
note "product: $product"
# fastboot answers with the SoC platform codename on this firmware ("pineapple"
# for SM8650), so match against the configured allowlist instead of a single
# hard-coded string.
allowed=0
for candidate in ${CAIHONG_FASTBOOT_PRODUCTS:-caihong}; do
	[ "$product" = "$candidate" ] && allowed=1
done
[ "$allowed" = 1 ] ||
	die "this device reports product '$product', which is not in CAIHONG_FASTBOOT_PRODUCTS (${CAIHONG_FASTBOOT_PRODUCTS:-caihong}); refusing to flash"

current_slot=$(fastboot getvar current-slot 2>&1 | awk -F': ' '/^current-slot:/ { print $2 }' | head -n 1)
note "current slot: ${current_slot:-unknown}"
[ "$current_slot" != "$slot" ] ||
	note "warning: Ubuntu would take over the slot that is active right now; Android on that slot stops booting"

partition="$variant"
partition_size=$(fastboot getvar "partition-size:$partition" 2>&1 |
	awk -F': ' '/^partition-size:/ { print $2 }' | head -n 1)
if [ -n "$partition_size" ]; then
	# fastboot reports partition sizes in bytes, usually as a hex literal; bash
	# arithmetic accepts both forms.
	partition_size=$((partition_size)) || die "cannot parse partition size: $partition_size"
	note "partition $partition: $((partition_size / 1024 / 1024)) MiB"
	[ "$partition_size" -ge "$logical_bytes" ] ||
		die "partition '$partition' is too small: $((partition_size / 1024 / 1024)) MiB < $((logical_bytes / 1024 / 1024)) MiB"
else
	note "warning: the bootloader did not report the size of partition '$partition'"
	note "         verify it manually before flashing (the image needs $((logical_bytes / 1024 / 1024)) MiB)"
fi

if [ -n "$vbmeta" ]; then
	[ -f "$vbmeta" ] || die "vbmeta file not found: $vbmeta"
	note "vbmeta: $(basename "$vbmeta") (Android Verified Boot will be disabled)"
else
	note "vbmeta: not provided; continuing on the assumption that verity/verification"
	note "        are already disabled for this device. If the bootloader rejects the"
	note "        boot image, flash the vbmeta.img from the matching Android factory"
	note "        image with --disable-verity --disable-verification."
fi

ops=()
if [ -n "$vbmeta" ]; then
	ops+=("fastboot --disable-verity --disable-verification flash vbmeta $vbmeta")
fi
ops+=("fastboot erase dtbo_$slot")
ops+=("fastboot flash boot_$slot $boot_image")
ops+=("fastboot flash $partition $rootfs_image")
ops+=("fastboot --set-active=$slot")
ops+=("fastboot reboot")

note ""
note "== operations that will be executed =="
for op in "${ops[@]}"; do
	note "  $op"
done

if [ "$variant" = "$ROOTFS_LABEL_SINGLE" ]; then
	note ""
	note "WARNING: the single-system variant writes over the '$partition' partition."
	note "         On a stock device that partition holds all Android user data,"
	note "         and it cannot be recovered from this script."
else
	note ""
	note "The dual-boot variant does not touch 'userdata': Android keeps its data."
	note "Only dtbo_$slot is erased, because the Caihong device tree is embedded in"
	note "the boot image and a stale DTBO would take precedence."
fi
note ""
note "rollback: reboot to the bootloader and 'fastboot --set-active=$([ "$slot" = a ] && echo b || echo a)',"
note "          then restore the original boot_$slot and dtbo_$slot images from your backup."

if [ "$apply" = 0 ]; then
	note ""
	note "dry run only: nothing was written."
	note "re-run with --apply to perform these operations."
	exit 0
fi

if [ "$assume_yes" = 0 ]; then
	printf 'Type "%s %s" to confirm flashing slot %s: ' "$product" "$variant" "$slot" >&2
	read -r confirmation
	[ "$confirmation" = "$product $variant" ] || die "confirmation did not match; nothing was written"
fi

note ""
note "== flashing =="
for op in "${ops[@]}"; do
	note "\$ $op"
	# shellcheck disable=SC2086
	$op || die "command failed: $op (device state: some operations may have completed)"
done

note ""
note "flashed. The first boot expands the root filesystem automatically"
note "(caihong-grow-rootfs.service) and is therefore slower than later boots."
note "If the panel stays dark, connect USB and run scripts/collect-debug.sh from"
note "the recovery environment, or read the kernel log over adb when adbd starts."
