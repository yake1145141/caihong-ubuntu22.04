#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
#
# Package the Caihong Android boot image v2 for the Ubuntu rootfs.
#
# The boot image carries the kernel Image and the Caihong device tree, and no
# ramdisk: the kernel mounts its root filesystem directly from UFS. Two variants
# exist because the reference project supports two installations:
#
#   linux     dual boot, root=PARTLABEL=linux    (Android stays in place)
#   userdata  single system, root=PARTLABEL=userdata (Android user data is lost)
#
# usage: scripts/package-ubuntu-boot.sh [OUTPUT_DIR]
#
# The resulting images are byte-compatible with the reference release layout:
# same page size, same load addresses, same header v2 size. The only intended
# differences are the command line and therefore the header SHA-1 id.
set -Eeuo pipefail
CDPATH=

project_dir=$(cd -- "$(dirname -- "$0")/.." && pwd)
# shellcheck source=config/ubuntu.env
. "$project_dir/config/ubuntu.env"

out_dir=${1:-"$project_dir/release"}
kernel_dir=${KERNEL_OUT:-"$project_dir/build/kernel"}
tool="$project_dir/tools/bootimg_v2.py"

die()
{
	printf 'error: %s\n' "$*" >&2
	exit 1
}

note()
{
	printf '%s\n' "$*"
}

[ -f "$kernel_dir/Image" ] || die "missing $kernel_dir/Image; run scripts/prepare-caihong-kernel.sh"
[ -f "$kernel_dir/caihong.dtb" ] || die "missing $kernel_dir/caihong.dtb"
[ -f "$kernel_dir/manifest.env" ] || die "missing $kernel_dir/manifest.env"
command -v python3 >/dev/null 2>&1 || die "python3 is required"
command -v sha256sum >/dev/null 2>&1 || die "sha256sum is required"

# The manifest records the device tree model, which contains spaces, so parse the
# keys instead of sourcing the file into the shell.
manifest_value()
{
	awk -F= -v key="$1" '$1 == key { sub(/^[^=]*=/, ""); gsub(/^"|"$/, ""); print; exit }' \
		"$kernel_dir/manifest.env"
}
manifest_image_sha=$(manifest_value KERNEL_IMAGE_SHA256)
manifest_dtb_sha=$(manifest_value KERNEL_DTB_SHA256)
KERNEL_IMAGE_SIZE=$(manifest_value KERNEL_IMAGE_SIZE)
KERNEL_DTB_SIZE=$(manifest_value KERNEL_DTB_SIZE)
image_sha=$(sha256sum "$kernel_dir/Image" | awk '{ print $1 }')
dtb_sha=$(sha256sum "$kernel_dir/caihong.dtb" | awk '{ print $1 }')
[ "$image_sha" = "$manifest_image_sha" ] ||
	die "kernel Image in $kernel_dir does not match the pinned digest"
[ "$dtb_sha" = "$manifest_dtb_sha" ] || die "device tree in $kernel_dir does not match the pinned digest"

mkdir -p "$out_dir"
out_dir=$(cd -- "$out_dir" && pwd)

pack_one()
{
	local label=$1
	local cmdline_file="$project_dir/config/caihong-ubuntu-cmdline-$label.txt"
	local output="$out_dir/caihong-ubuntu22.04-$UBUNTU_SUITE-boot-$label.img"

	[ -f "$cmdline_file" ] || die "missing command line file: $cmdline_file"
	local cmdline
	IFS= read -r cmdline < "$cmdline_file"
	case " $cmdline " in
		*" root=PARTLABEL=$label "*) ;;
		*) die "$cmdline_file must contain root=PARTLABEL=$label" ;;
	esac
	case " $cmdline " in
		*" rdinit="*|*" root=LABEL="*)
			die "$cmdline_file references an initramfs root, but this image has none"
			;;
	esac

	if [ -e "$output" ]; then
		[ "${FORCE:-0}" = 1 ] || die "refusing to overwrite $output (set FORCE=1)"
		rm -f -- "$output"
	fi

	note "packing boot image for root=PARTLABEL=$label"
	python3 "$tool" pack \
		--kernel "$kernel_dir/Image" \
		--dtb "$kernel_dir/caihong.dtb" \
		--cmdline "$cmdline_file" \
		--output "$output" \
		--os-version "$BOOT_OS_VERSION" \
		--os-patch-level "$BOOT_OS_PATCH_LEVEL" >/dev/null ||
		die "cannot pack $output"

	# Re-read the image with the independent parser: a boot image that only the
	# writer believes in is worthless.
	python3 "$tool" info "$output" --expect-cmdline "root=PARTLABEL=$label" >/dev/null ||
		die "self-check failed for $output"
	local header_version dtb_size kernel_size
	header_version=$(python3 "$tool" info "$output" | awk -F': ' '/^header_version/ { print $2 }')
	dtb_size=$(python3 "$tool" info "$output" | awk -F'[:= ]+' '/^dtb +: / { print $5 }')
	kernel_size=$(python3 "$tool" info "$output" | awk -F': ' '/^kernel_size/ { print $2 }')
	[ "$header_version" = "$BOOT_HEADER_VERSION" ] ||
		die "$output has header version $header_version, expected $BOOT_HEADER_VERSION"
	[ "$dtb_size" = "$KERNEL_DTB_SIZE" ] ||
		die "$output embeds $dtb_size DTB bytes, expected $KERNEL_DTB_SIZE"
	[ "$kernel_size" = "$KERNEL_IMAGE_SIZE" ] ||
		die "$output embeds $kernel_size kernel bytes, expected $KERNEL_IMAGE_SIZE"

	(
		cd "$out_dir"
		sha256sum "$(basename "$output")" > "$(basename "$output").sha256"
	)
	note "  $(basename "$output")  $(stat -c %s "$output") bytes"
	note "  $(cat "$output.sha256")"
}

pack_one "$ROOTFS_LABEL_DUALBOOT"
pack_one "$ROOTFS_LABEL_SINGLE"

note ""
note "boot images written to $out_dir"
note "kernel release: $KERNEL_RELEASE"
note "header: Android boot image v$BOOT_HEADER_VERSION, page size $BOOT_PAGE_SIZE, no ramdisk"
