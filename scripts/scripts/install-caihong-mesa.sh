#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
#
# Install the Caihong Mesa bundle into an Ubuntu rootfs tree.
#
# Why this exists: Ubuntu 22.04 ships Mesa 23.2.1. Its freedreno kgsl backend
# crashes with SIGSEGV right after DRM_IOCTL_MSM_SUBMITQUEUE_NEW on the Adreno 750
# (verified on hardware, see docs/DEVICE-TEST-2026-10-30.zh-CN.md), so the panel
# works but no GPU rendering is possible. Mesa 24.3.4 with freedreno + turnip was
# built natively on the device and produced:
#
#   OpenGL ES 3.2 Mesa 24.3.4, vendor "freedreno", renderer "FD750"
#   Vulkan: "Turnip Adreno (TM) 750", driver "turnip Mesa driver"
#
# The bundle is the exact tree that was validated, installed over the system Mesa.
# It is a glvnd-less build, which is fine for a console-only server image whose
# only GL consumers are kmscube/glmark2/vulkaninfo; libglvnd's libEGL.so.1 is
# replaced by Mesa's own implementation from the bundle.
#
# usage: install-caihong-mesa.sh BUNDLE.tar.zst ROOTFS_DIR
set -Eeuo pipefail
CDPATH=

project_dir=$(cd -- "$(dirname -- "$0")/.." && pwd)
bundle=${1:-}
target=${2:-}

die()
{
	printf 'error: %s\n' "$*" >&2
	exit 1
}

note()
{
	printf '%s\n' "$*"
}

[ -n "$bundle" ] && [ -n "$target" ] || die "usage: $0 BUNDLE.tar.zst ROOTFS_DIR"
[ -f "$bundle" ] || die "bundle not found: $bundle"
[ -d "$target/usr/lib" ] || die "not a rootfs tree: $target"
command -v bsdtar >/dev/null 2>&1 || die "bsdtar is required"
command -v zstd >/dev/null 2>&1 || die "zstd is required"

libdir=$target/usr/lib/aarch64-linux-gnu
[ -d "$libdir" ] || die "missing $libdir (is this an arm64 rootfs?)"

# Prove the bundle is aarch64 before touching the tree.
work=$(mktemp -d "${TMPDIR:-/tmp}/caihong-mesa.XXXXXX")
trap 'rm -rf -- "$work"' EXIT HUP INT TERM
bsdtar -xf "$bundle" -C "$work"
sample="$work/lib/aarch64-linux-gnu/libEGL.so.1.0.0"
[ -f "$sample" ] || die "bundle layout is not expected: $sample missing"
machine=$(readelf -h "$sample" 2>/dev/null | awk -F: '/^ *Machine:/ { gsub(/^ +| +$/, "", $2); print $2 }')
[ "$machine" = "AArch64" ] || die "bundle is not an aarch64 build (machine: ${machine:-unknown})"

note "installing Mesa $(basename "$bundle") into $libdir"

# The old Mesa megadriver must go, otherwise the loader can pick it up again.
rm -f "$libdir"/libgallium-*.so

for entry in "$work"/lib/aarch64-linux-gnu/*; do
	[ -e "$entry" ] || [ -L "$entry" ] || continue
	# Subdirectories (the GBM backend directory) are not runtime libraries.
	if [ -d "$entry" ] && [ ! -L "$entry" ]; then
		continue
	fi
	name=${entry##*/}
	# Documentation, headers and the archive tools are build leftovers; only the
	# runtime libraries and ICDs belong in the image.
	case "$name" in
		libarchive*|libxatracker*) continue ;;
	esac
	# Remove the destination first: cp would otherwise follow an existing symlink
	# (Ubuntu points libEGL.so.1 at glvnd's libEGL.so.1.1.0) and write through it,
	# leaving the loader on the old Mesa stack.
	rm -f "$libdir/$name"
	cp -a "$entry" "$libdir/$name"
done

# ldconfig (triggered by any later dpkg/apt run) rebuilds soname links from the
# libs it finds, and Ubuntu's glvnd libraries declare the same sonames. Recreate
# the links explicitly so the loader always picks the Mesa 24 files.
for pair in libEGL.so.1:libEGL.so.1.0.0 libGLESv2.so.2:libGLESv2.so.2.0.0 libgbm.so.1:libgbm.so.1.0.0; do
	link=${pair%%:*}
	target=${pair#*:}
	[ -f "$libdir/$target" ] || continue
	ln -sfn "$target" "$libdir/$link"
done

# Vulkan ICD for Turnip.
install -d -m 0755 "$target/usr/share/vulkan/icd.d"
for icd in "$work"/share/vulkan/icd.d/*.json; do
	[ -f "$icd" ] || continue
	install -m 0644 "$icd" "$target/usr/share/vulkan/icd.d/$(basename "$icd")"
done

# Mesa 24 does not need per-driver symlinks for EGL, but the DRI directory is
# still consulted by some loaders; keep it consistent when the bundle has one.
if [ -d "$work/lib/aarch64-linux-gnu/dri" ]; then
	install -d -m 0755 "$libdir/dri"
	rm -f "$libdir"/dri/*.so
	cp -a "$work/lib/aarch64-linux-gnu/dri/." "$libdir/dri/"
fi

# Record what is installed so the image can be audited later.
cat > "$target/usr/share/caihong-mesa.txt" <<EOF
bundle=$(basename "$bundle")
mesa_version=24.3.4
gl_renderer=FD750
vulkan_device=Turnip Adreno (TM) 750
gallium_drivers=freedreno
vulkan_drivers=freedreno
platforms=none (console only)
verified_on_device=2026-10-30
reason=Ubuntu 22.04 Mesa 23.2.1 segfaults in the kgsl backend on Adreno 750
EOF
chmod 0644 "$target/usr/share/caihong-mesa.txt"

note "Mesa 24.3.4 installed into $target"
ls -1 "$libdir" | grep -E 'lib(gallium|EGL|GLESv2|gbm|vulkan_freedreno)' || true
