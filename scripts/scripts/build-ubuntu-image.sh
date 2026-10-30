#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
#
# Turn the Ubuntu rootfs tree into the installable root filesystem image for the
# OnePlus Pad Pro.
#
# The output is an Android sparse ext4 image because that is what
# `fastboot flash linux <image>` expects on this device, and because a 6 GiB raw
# image is impractical to distribute. The filesystem label is the same string the
# boot image uses in root=PARTLABEL=..., so a flashed image boots without any
# manual fstab editing.
#
# usage: sudo scripts/build-ubuntu-image.sh [ROOTFS_DIR] [OUTPUT]
#
# environment:
#   ROOT_PARTLABEL   linux (default) or userdata
#   SPARSE           1 (default) to emit an Android sparse image, 0 for raw
#   COMPRESS         1 (default) to zstd-compress the result
#   SPLIT_MIB        split the compressed stream above this size (default 1900)
#   IMAGE_SIZE_GIB   force the logical filesystem size
set -Eeuo pipefail
CDPATH=

project_dir=$(cd -- "$(dirname -- "$0")/.." && pwd)
# shellcheck source=config/ubuntu.env
. "$project_dir/config/ubuntu.env"

rootfs=${1:-"$project_dir/build/rootfs"}
output=${2:-""}
label=${ROOT_PARTLABEL:-$ROOTFS_LABEL_DUALBOOT}
sparse=${SPARSE:-1}
compress=${COMPRESS:-1}
split_mib=${SPLIT_MIB:-1900}
zstd_level=${ZSTD_LEVEL:-10}
image_size_gib=${IMAGE_SIZE_GIB:-}

die()
{
	printf 'error: %s\n' "$*" >&2
	exit 1
}

note()
{
	printf '%s\n' "$*"
}

[ "$(id -u)" -eq 0 ] || die "run as root: ext4 ownership and device numbers must be exact"
[ -d "$rootfs" ] || die "rootfs tree not found: $rootfs"
rootfs=$(cd -- "$rootfs" && pwd)

case "$label" in
	"$ROOTFS_LABEL_DUALBOOT"|"$ROOTFS_LABEL_SINGLE") ;;
	*) die "unsupported root partition label: $label" ;;
esac
case "$sparse" in 0|1) ;; *) die "SPARSE must be 0 or 1" ;; esac
case "$compress" in 0|1) ;; *) die "COMPRESS must be 0 or 1" ;; esac

for tool in mkfs.ext4 e2fsck resize2fs dumpe2fs blkid du truncate sha256sum; do
	command -v "$tool" >/dev/null 2>&1 || die "missing host tool: $tool"
done
if [ "$sparse" = 1 ]; then
	for tool in img2simg simg2img; do
		command -v "$tool" >/dev/null 2>&1 ||
			die "missing $tool (apt install android-sdk-libsparse-utils)"
	done
fi
if [ "$compress" = 1 ]; then
	command -v zstd >/dev/null 2>&1 || die "missing zstd"
fi

# Refuse to package a half-built tree: these are the files a bootable image must
# contain, and a missing one turns into an unbootable device rather than an error.
[ -x "$rootfs/usr/lib/systemd/systemd" ] || die "rootfs has no systemd: $rootfs"
[ -f "$rootfs/etc/os-release" ] || die "rootfs has no /etc/os-release"
grep -q '^ID=ubuntu' "$rootfs/etc/os-release" || die "rootfs is not an Ubuntu user space"
grep -q '^VERSION_ID="22.04"' "$rootfs/etc/os-release" || die "rootfs is not Ubuntu 22.04"
[ -f "$rootfs/etc/caihong-rootfs-build-info" ] || die "rootfs was not produced by build-ubuntu-rootfs.sh"
[ -d "$rootfs/lib/modules" ] || die "rootfs has no kernel modules"
module_dirs=("$rootfs"/lib/modules/*/)
[ ${#module_dirs[@]} -eq 1 ] || die "rootfs must carry exactly one kernel release"
[ -f "${module_dirs[0]}modules.dep" ] || die "rootfs module tree has no modules.dep"
[ ! -e "$rootfs/usr/bin/qemu-aarch64-static" ] || die "rootfs still contains the qemu cross interpreter"
if [ -s "$rootfs/etc/machine-id" ]; then
	die "rootfs machine-id is not empty; every device would share it"
fi
if [ -e "$rootfs/etc/resolv.conf" ] && [ ! -L "$rootfs/etc/resolv.conf" ]; then
	note "warning: /etc/resolv.conf is a static file, not the systemd-resolved link"
fi
grep -q "PARTLABEL=$label" "$rootfs/etc/fstab" ||
	die "rootfs fstab does not reference PARTLABEL=$label (was it built with ROOT_PARTLABEL=$label?)"

mkdir -p "$project_dir/release"
if [ -z "$output" ]; then
	suffix=.ext4.sparse.img
	if [ "$sparse" = 0 ]; then
		suffix=.ext4.img
	fi
	out_dir=$(cd -- "$project_dir/release" && pwd)
	output="$out_dir/caihong-ubuntu22.04-rootfs-$label$suffix"
else
	# Resolve the directory once and rebuild the path from it: appending a
	# relative name to an already-absolute directory would duplicate the
	# directory part and produce release/release/....
	output_dir=$(dirname -- "$output")
	mkdir -p "$output_dir"
	out_dir=$(cd -- "$output_dir" && pwd)
	output="$out_dir/$(basename -- "$output")"
fi

if [ -e "$output" ] || [ -e "$output.part" ]; then
	[ "${FORCE:-0}" = 1 ] || die "refusing to overwrite $output (set FORCE=1)"
	rm -f -- "$output" "$output.part"
fi

work_dir=$(mktemp -d "$project_dir/build/image.XXXXXX")
trap 'rm -rf -- "$work_dir"' EXIT HUP INT TERM

# --- size policy -------------------------------------------------------------
used_bytes=$(du -sx --block-size=1 "$rootfs" | awk 'NR == 1 { print $1 }')
free_via_percent=$((used_bytes * ROOTFS_IMAGE_SLACK_PERCENT / 100))
free_via_floor=$((ROOTFS_IMAGE_MIN_FREE_MIB * 1024 * 1024))
if [ "$free_via_percent" -gt "$free_via_floor" ]; then
	free_bytes=$free_via_percent
else
	free_bytes=$free_via_floor
fi
required_bytes=$((used_bytes + free_bytes))

if [ -n "$image_size_gib" ]; then
	image_bytes=$((image_size_gib * 1024 * 1024 * 1024))
	[ "$image_bytes" -ge "$required_bytes" ] ||
		die "IMAGE_SIZE_GIB=$image_size_gib is too small (need $((required_bytes / 1024 / 1024)) MiB)"
else
	step=$((256 * 1024 * 1024))
	image_bytes=$(((required_bytes + step - 1) / step * step))
fi

note "rootfs tree      : $rootfs"
note "used             : $((used_bytes / 1024 / 1024)) MiB"
note "logical size     : $((image_bytes / 1024 / 1024)) MiB"
note "filesystem label : $label"

# --- build the filesystem ----------------------------------------------------
raw="$work_dir/rootfs.raw.img"
note "creating the ext4 filesystem"
truncate -s "$image_bytes" "$raw"
mkfs.ext4 -q -F -L "$label" -m 0 -t ext4 \
	-E lazy_itable_init=0,lazy_journal_init=0,root_owner=0:0 \
	-d "$rootfs" "$raw" ||
	die "mkfs.ext4 failed to populate the image from $rootfs"

# The device grows the filesystem to the partition on first boot, so the image
# only has to be internally consistent now.
e2fsck -fn "$raw" >"$work_dir/e2fsck.log" 2>&1 || {
	cat "$work_dir/e2fsck.log" >&2
	die "e2fsck rejected the generated filesystem"
}
actual_label=$(blkid -s LABEL -o value "$raw")
[ "$actual_label" = "$label" ] ||
	die "generated filesystem is labelled '$actual_label', expected '$label'"

# --- package -----------------------------------------------------------------
if [ "$sparse" = 1 ]; then
	note "converting to an Android sparse image"
	img2simg "$raw" "$work_dir/sparse.img" >/dev/null || die "img2simg failed"
	# Read the sparse image back through the Android decoder to prove every chunk
	# descriptor is valid; writing to /dev/null validates without another 6 GiB.
	simg2img "$work_dir/sparse.img" /dev/null >/dev/null 2>&1 ||
		die "the generated sparse image is not decodable"
	mv -- "$work_dir/sparse.img" "$output.part"
else
	mv -- "$raw" "$output.part"
fi
mv -- "$output.part" "$output"

final_size=$(stat -c %s "$output")
artifact=$output
artifacts=("$output")

# Verify the filesystem while it still exists in its installable form: once it is
# compressed and split, a structural error would only surface on the device.
note "verifying the generated filesystem image"
"$project_dir/scripts/verify-ubuntu-image.sh" --image "$output" --quiet ||
	die "the generated image failed verification: $output"

if [ "$compress" = 1 ]; then
	note "compressing with zstd -$zstd_level"
	zstd -q -T0 "-$zstd_level" -o "$output.zst" --force "$output" || die "zstd failed"
	rm -f -- "$output"
	artifact="$output.zst"
	artifacts=("$output.zst")

	split_bytes=$((split_mib * 1024 * 1024))
	if [ "$(stat -c %s "$output.zst")" -gt "$split_bytes" ]; then
		note "splitting the compressed stream into ${split_mib} MiB parts"
		rm -f "$output".zst.part-*
		split -b "$split_bytes" -d -a 2 "$output.zst" "$output.zst.part-"
		rm -f -- "$output.zst"
		artifacts=()
		for part in "$output".zst.part-*; do
			artifacts+=("$part")
		done
	fi
fi

# --- metadata ----------------------------------------------------------------
manifest="$out_dir/caihong-ubuntu22.04-$label-manifest.env"
cat > "$manifest" <<EOF
# Build manifest for the Caihong Ubuntu 22.04 root filesystem image.
image_label=$label
image_logical_bytes=$image_bytes
image_logical_mib=$((image_bytes / 1024 / 1024))
image_sparse=$sparse
image_compressed=$compress
rootfs_used_bytes=$used_bytes
kernel_release=$(awk -F= '/^kernel_release=/{print $2}' "$rootfs/etc/caihong-rootfs-build-info")
kernel_image_sha256=$(awk -F= '/^kernel_image_sha256=/{print $2}' "$rootfs/etc/caihong-rootfs-build-info")
kernel_dtb_sha256=$(awk -F= '/^kernel_dtb_sha256=/{print $2}' "$rootfs/etc/caihong-rootfs-build-info")
built_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

(
	cd "$out_dir"
	: > "caihong-ubuntu22.04-$label-SHA256SUMS"
	for file in "${artifacts[@]}"; do
		sha256sum "$(basename "$file")" >> "caihong-ubuntu22.04-$label-SHA256SUMS"
	done
	sha256sum "$(basename "$manifest")" >> "caihong-ubuntu22.04-$label-SHA256SUMS"
)

note ""
note "image written to $out_dir"
for file in "${artifacts[@]}"; do
	printf '  %-70s %10s MiB\n' "$(basename "$file")" "$(($(stat -c %s "$file") / 1024 / 1024))"
done
note "  $(basename "$manifest")"
note "  caihong-ubuntu22.04-$label-SHA256SUMS"
if [ "$final_size" -gt 0 ] && [ "$sparse" = 1 ]; then
	note "sparse image size: $(stat -c %s "$output" 2>/dev/null || echo '(compressed)') bytes"
fi
