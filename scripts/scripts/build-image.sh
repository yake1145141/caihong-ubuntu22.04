#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
#
# One-shot reproducible build of the Caihong Ubuntu 22.04 installation set.
#
#   scripts/prepare-caihong-kernel.sh   kernel, DTB, modules, embedded config
#   scripts/build-ubuntu-rootfs.sh      Ubuntu Jammy arm64 user space
#   scripts/package-ubuntu-boot.sh      Android boot image v2 (linux + userdata)
#   scripts/build-ubuntu-image.sh       Android sparse ext4 root filesystem
#   scripts/verify-ubuntu-image.sh      structural verification
#
# usage: sudo scripts/build-image.sh [--variant both|linux|userdata] [--skip-rootfs]
#
# Outputs land in release/:
#   caihong-ubuntu22.04-jammy-boot-linux.img
#   caihong-ubuntu22.04-jammy-boot-userdata.img
#   caihong-ubuntu22.04-rootfs-linux.ext4.sparse.img.zst(.part-NN)
#   caihong-ubuntu22.04-rootfs-userdata.ext4.sparse.img.zst(.part-NN)
#   caihong-ubuntu22.04-<label>-SHA256SUMS, caihong-ubuntu22.04-<label>-manifest.env
set -Eeuo pipefail
CDPATH=

project_dir=$(cd -- "$(dirname -- "$0")/.." && pwd)
# shellcheck source=config/ubuntu.env
. "$project_dir/config/ubuntu.env"

variant=both
skip_rootfs=0
while [ $# -gt 0 ]; do
	case $1 in
		--variant) variant=${2:?--variant needs a value}; shift 2 ;;
		--skip-rootfs) skip_rootfs=1; shift ;;
		-h|--help) sed -n '2,25p' "$0"; exit 0 ;;
		*) echo "unknown option: $1" >&2; exit 2 ;;
	esac
done
case "$variant" in
	both|linux|userdata) ;;
	*) echo "--variant must be both, linux or userdata" >&2; exit 2 ;;
esac

[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }

kernel_dir="$project_dir/build/kernel"
rootfs="$project_dir/build/rootfs"
release_dir="$project_dir/release"
start=$(date +%s)

step()
{
	printf '\n\033[1m==> %s\033[0m\n' "$*"
}

elapsed()
{
	printf '    (%ds elapsed)\n' "$(( $(date +%s) - start ))"
}

step "preparing the Caihong kernel, device tree and modules"
"$project_dir/scripts/prepare-caihong-kernel.sh"
elapsed

labels=()
case "$variant" in
	both) labels=("$ROOTFS_LABEL_DUALBOOT" "$ROOTFS_LABEL_SINGLE") ;;
	linux) labels=("$ROOTFS_LABEL_DUALBOOT") ;;
	userdata) labels=("$ROOTFS_LABEL_SINGLE") ;;
esac

if [ "$skip_rootfs" = 0 ]; then
	step "building the Ubuntu $UBUNTU_SUITE arm64 root filesystem"
	# The root entry in /etc/fstab differs between the two layouts; the tree is
	# built once for the dual-boot label and patched per variant below.
	FORCE=1 ROOT_PARTLABEL="$ROOTFS_LABEL_DUALBOOT" \
		"$project_dir/scripts/build-ubuntu-rootfs.sh" "$rootfs"
	elapsed
else
	[ -d "$rootfs" ] || { echo "--skip-rootfs needs an existing $rootfs" >&2; exit 1; }
fi

step "packaging the boot images"
FORCE=1 "$project_dir/scripts/package-ubuntu-boot.sh" "$release_dir"
elapsed

# Swap the single root entry in fstab for the label of the variant being imaged,
# and always restore the tree afterwards, including on failure.
original_fstab="$rootfs/etc/fstab"
fstab_backup=$(mktemp)
cp -- "$original_fstab" "$fstab_backup"
restore_fstab()
{
	cp -- "$fstab_backup" "$original_fstab"
	rm -f -- "$fstab_backup"
}
trap restore_fstab EXIT HUP INT TERM

for label in "${labels[@]}"; do
	step "building the root filesystem image for PARTLABEL=$label"
	sed -i "s|^PARTLABEL=[^[:space:]]*|PARTLABEL=$label|" "$original_fstab"
	grep -q "^PARTLABEL=$label" "$original_fstab" ||
		{ echo "cannot set the root label in $original_fstab" >&2; exit 1; }
	ROOT_PARTLABEL="$label" FORCE=1 \
		"$project_dir/scripts/build-ubuntu-image.sh" "$rootfs" \
		"$release_dir/caihong-ubuntu22.04-rootfs-$label.ext4.sparse.img"
	elapsed
done

restore_fstab
trap - EXIT HUP INT TERM

step "verifying the build"
verify_args=(--rootfs "$rootfs")
for label in "${labels[@]}"; do
	verify_args+=(--boot "$release_dir/caihong-ubuntu22.04-$UBUNTU_SUITE-boot-$label.img")
	# Verify the compressed artifact exactly as a user would download it. Split
	# streams are verified inside build-ubuntu-image.sh before splitting.
	if [ -f "$release_dir/caihong-ubuntu22.04-rootfs-$label.ext4.sparse.img.zst" ]; then
		verify_args+=(--image "$release_dir/caihong-ubuntu22.04-rootfs-$label.ext4.sparse.img.zst")
	fi
done
"$project_dir/scripts/verify-ubuntu-image.sh" "${verify_args[@]}"
elapsed

step "build summary"
printf 'release directory: %s\n' "$release_dir"
ls -1sh "$release_dir" | grep -E 'ubuntu22\.04' || true
printf '\nThis build is reproducible from:\n'
printf '  kernel package : %s\n' "$KERNEL_PACKAGE_NAME"
printf '  kernel release : %s\n' "$KERNEL_RELEASE"
printf '  Ubuntu suite   : %s (%s)\n' "$UBUNTU_SUITE" "$UBUNTU_ARCH"
printf '  debootstrap    : %s\n' "$(debootstrap --version 2>/dev/null || echo unknown)"
printf '\nThe image is NOT flashed by this script. Use scripts/install-dualboot.sh\n'
printf 'to review the exact fastboot operations first.\n'
