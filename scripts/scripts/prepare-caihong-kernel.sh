#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
#
# Extract and verify the Caihong kernel, device tree and module tree that the
# Ubuntu rootfs will ship.
#
# The reference project builds the kernel itself. The Ubuntu port deliberately
# reuses the *published* linux-caihong package instead, because keeping the
# validated kernel/DTB/firmware combination is more valuable than rebuilding it,
# and because the package is the only artifact that carries the exact module ABI
# that the device tree and firmware were tested against.
#
# usage: scripts/prepare-caihong-kernel.sh [KERNEL_PACKAGE]
#
# outputs (below $KERNEL_OUT, default build/kernel):
#   Image                     validated arm64 Image, extracted from the boot image
#   caihong.dtb               validated device tree, extracted from the boot image
#   kconfig                   kernel configuration recovered from the Image
#   boot-linux.img            reference dual-boot image (root=PARTLABEL=linux)
#   boot-userdata.img         reference single-system image (root=PARTLABEL=userdata)
#   lib/modules/<release>/    module tree with regenerated dependency metadata
#   manifest.env              everything the later stages need to assert on
set -Eeuo pipefail
CDPATH=

project_dir=$(cd -- "$(dirname -- "$0")/.." && pwd)
# shellcheck source=config/ubuntu.env
. "$project_dir/config/ubuntu.env"

package=${1:-"${KERNEL_PACKAGE:-$project_dir/release/$KERNEL_PACKAGE_NAME}"}
out=${KERNEL_OUT:-"$project_dir/build/kernel"}
bootimg_tool="$project_dir/tools/bootimg_v2.py"

die()
{
	printf 'error: %s\n' "$*" >&2
	exit 1
}

note()
{
	printf '%s\n' "$*"
}

[ "$(id -u)" -eq 0 ] || die "run as root: module ownership and depmod must be exact"
[ -f "$package" ] || die "kernel package not found: $package (pass it as the first argument)"
for tool in bsdtar python3 depmod fdtget sha256sum find; do
	command -v "$tool" >/dev/null 2>&1 || die "missing host tool: $tool"
done

note "verifying $package"
actual=$(sha256sum "$package" | awk '{ print $1 }')
if [ -n "${KERNEL_PACKAGE_SHA256:-}" ]; then
	[ "$actual" = "$KERNEL_PACKAGE_SHA256" ] ||
		die "kernel package checksum mismatch
  expected $KERNEL_PACKAGE_SHA256
  actual   $actual
refusing to build a rootfs around an unverified kernel"
else
	note "warning: KERNEL_PACKAGE_SHA256 is unset, the kernel package is not pinned"
fi

mkdir -p "$project_dir/build"
work=$(mktemp -d "$project_dir/build/prepare-kernel.XXXXXX")
trap 'rm -rf -- "$work"' EXIT HUP INT TERM

note "unpacking the kernel package"
bsdtar -xf "$package" -C "$work"
pkg_root="$work"
[ -d "$pkg_root/usr/lib/linux-caihong" ] || die "unexpected package layout: usr/lib/linux-caihong is missing"

release=$(tr -d ' \t\r\n' < "$pkg_root/usr/lib/linux-caihong/kernel-release")
[ -n "$release" ] || die "package does not record a kernel release"
[ "$release" = "$KERNEL_RELEASE" ] ||
	die "kernel release mismatch: package says $release, config/ubuntu.env pins $KERNEL_RELEASE"

mkdir -p "$out"
rm -rf -- "$out/Image" "$out/caihong.dtb" "$out/kconfig" "$out/lib" "$out/boot-linux.img" \
	"$out/boot-userdata.img" "$out/manifest.env"

# The device tree only exists inside the boot image: the release does not ship
# it as a standalone file, and the copy inside the boot image is the one the
# bootloader actually consumed on hardware.
note "extracting Image and DTB from the packaged boot image"
for variant in linux userdata; do
	src="$pkg_root/usr/lib/linux-caihong/boot-$variant.img"
	[ -f "$src" ] || die "package is missing boot-$variant.img"
	cp -- "$src" "$out/boot-$variant.img"
	rm -rf -- "$work/unpack-$variant"
	python3 "$bootimg_tool" unpack "$src" "$work/unpack-$variant" >/dev/null ||
		die "cannot parse boot-$variant.img"
done

cp -- "$work/unpack-linux/kernel" "$out/Image"
cp -- "$work/unpack-linux/dtb" "$out/caihong.dtb"

image_sha=$(sha256sum "$out/Image" | awk '{ print $1 }')
dtb_sha=$(sha256sum "$out/caihong.dtb" | awk '{ print $1 }')
[ "$image_sha" = "$KERNEL_IMAGE_SHA256" ] ||
	die "kernel Image digest mismatch
  expected $KERNEL_IMAGE_SHA256
  actual   $image_sha"
[ "$dtb_sha" = "$KERNEL_DTB_SHA256" ] ||
	die "device tree digest mismatch
  expected $KERNEL_DTB_SHA256
  actual   $dtb_sha"

# The single-system image must carry the very same kernel: only the root device
# differs between the two release variants.
if ! cmp -s "$work/unpack-linux/kernel" "$work/unpack-userdata/kernel"; then
	die "the linux and userdata boot images carry different kernels"
fi

note "verifying the device tree identity"
model=$(fdtget -t s "$out/caihong.dtb" / model 2>/dev/null || true)
compatible=$(fdtget -t s "$out/caihong.dtb" / compatible 2>/dev/null || true)
[ -n "$model" ] || die "device tree has no /model"
case " $compatible " in
	*" oneplus,caihong "*) ;;
	*) die "device tree is not for caihong: compatible=$compatible" ;;
esac
case " $compatible " in
	*" qcom,sm8650 "*) ;;
	*) note "warning: device tree does not advertise qcom,sm8650" ;;
esac

# Recover the kernel configuration from the Image. The package ships no config
# file, but the kernel was built with CONFIG_IKCONFIG=y, and that embedded blob
# is the only authoritative record of what the running kernel actually has.
note "recovering the embedded kernel configuration"
python3 - "$out/Image" "$out/kconfig" <<'PY'
import bz2
import gzip
import io
import lzma
import sys
import zlib

image_path, out_path = sys.argv[1], sys.argv[2]
data = open(image_path, "rb").read()
start = data.find(b"IKCFG_ST")
end = data.find(b"IKCFG_ED", start + 1 if start >= 0 else 0)
if start < 0 or end < 0:
    sys.exit("kernel Image has no embedded configuration (CONFIG_IKCONFIG=n); "
             "cannot prove the features the Ubuntu rootfs depends on")
blob = data[start + 8:end]
for name, decoder in (("gzip", lambda b: gzip.GzipFile(fileobj=io.BytesIO(b)).read()),
                      ("xz", lzma.decompress), ("bzip2", bz2.decompress),
                      ("zlib", zlib.decompress)):
    try:
        text = decoder(blob)
    except Exception:
        continue
    if b"CONFIG_" in text:
        with open(out_path, "wb") as handle:
            handle.write(text)
        print(f"kernel configuration decoded as {name} ({len(text.splitlines())} lines)")
        break
else:
    sys.exit("cannot decode the embedded kernel configuration")
PY

# These are the kernel guarantees the Ubuntu Server image is built on. Without
# them the image would not reach a console, would not mount its root filesystem
# without an initramfs, or could not report battery state.
note "checking the kernel features the image relies on"
check_config()
{
	key=$1
	want=$2
	why=$3
	line=$(grep -E "^$key=" "$out/kconfig" || true)
	if [ -z "$line" ]; then
		disabled=$(grep -E "^# $key is not set$" "$out/kconfig" || true)
		if [ -n "$disabled" ]; then
			die "$key is disabled but required: $why"
		fi
		note "warning: $key is absent from the kernel configuration ($why)"
		return 0
	fi
	value=${line#*=}
	value=${value//\"/}
	[ "$value" = "$want" ] || die "$key is '$value', expected '$want': $why"
	note "  $key=$value"
}

check_config CONFIG_EXT4_FS y "the root filesystem must be mountable without an initramfs"
check_config CONFIG_SCSI_UFSHCD y "UFS must be built in, the root partition lives on it"
check_config CONFIG_SCSI_UFS_QCOM y "the Qualcomm UFS host controller must be built in"
check_config CONFIG_DRM_FBDEV_EMULATION y "the internal panel only shows a text console through fbdev"
check_config CONFIG_FRAMEBUFFER_CONSOLE y "the internal panel must show the kernel and getty console"
check_config CONFIG_VT_CONSOLE y "the tty0 console must reach the framebuffer"
check_config CONFIG_DRM_MSM m "the display/GPU driver must stay a module so it loads from this rootfs"
check_config CONFIG_BATTERY_QCOM_BATTMGR y "battery capacity and status come from the PMIC battery manager"
check_config CONFIG_TYPEC y "USB-C role detection is required for OTG and charging"
check_config CONFIG_TYPEC_DP_ALTMODE y "DisplayPort alt mode requires the Type-C altmode core"

note "installing the module tree for $release"
mkdir -p "$out/lib/modules"
rm -rf -- "$out/lib/modules/$release"
cp -a "$pkg_root/usr/lib/linux-caihong/modules/$release" "$out/lib/modules/$release"
# Regenerate the dependency metadata with the host's kmod instead of trusting
# the copy produced during the package build: a stale modules.dep silently
# disables whole drivers.
depmod -b "$out" "$release"
[ -s "$out/lib/modules/$release/modules.dep" ] || die "depmod produced no modules.dep"
module_count=$(find "$out/lib/modules/$release" -name '*.ko' | wc -l)
builtin_count=$(wc -l < "$out/lib/modules/$release/modules.builtin")

cat > "$out/manifest.env" <<EOF
KERNEL_RELEASE=$release
KERNEL_PACKAGE="$(basename "$package")"
KERNEL_PACKAGE_SHA256=$actual
KERNEL_IMAGE_SHA256=$image_sha
KERNEL_IMAGE_SIZE=$(stat -c %s "$out/Image")
KERNEL_DTB_SHA256=$dtb_sha
KERNEL_DTB_SIZE=$(stat -c %s "$out/caihong.dtb")
KERNEL_DTB_MODEL="$model"
KERNEL_DTB_COMPATIBLE="$compatible"
KERNEL_MODULE_COUNT=$module_count
KERNEL_BUILTIN_COUNT=$builtin_count
EOF
chmod 0644 "$out/manifest.env"

note ""
note "kernel prepared in $out"
for line in MODULES="$module_count modules ($builtin_count built in)" \
	IMAGE="$image_sha" DTB="$dtb_sha" MODEL="$model" RELEASE="$release"; do
	note "  $line"
done
