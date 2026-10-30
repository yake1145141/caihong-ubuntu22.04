#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
#
# Install the Caihong Mesa bundle into an Ubuntu rootfs tree.
#
# Why this exists: Ubuntu 22.04 ships Mesa 23.2.1, whose freedreno kgsl backend
# crashes with SIGSEGV on the Adreno 750 immediately after
# DRM_IOCTL_MSM_SUBMITQUEUE_NEW (verified on hardware, in both the hardware and
# the software rendering path). Mesa 24.3.4 works and reports
#   OpenGL ES 3.2 Mesa 24.3.4, vendor "freedreno", renderer "FD750"
#   Vulkan: "Turnip Adreno (TM) 750"
#
# The bundle MUST be built with --prefix=/usr. A build configured with any other
# prefix embeds that prefix into libgbm's backend lookup path and into the Vulkan
# ICD json, and the resulting files crash or get skipped once installed elsewhere.
# scripts/build-caihong-mesa.sh always uses --prefix=/usr.
#
# usage: install-caihong-mesa.sh BUNDLE.tar.zst ROOTFS_DIR
set -Eeuo pipefail
CDPATH=

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
for tool in bsdtar zstd readelf rsync; do
	command -v "$tool" >/dev/null 2>&1 || die "missing host tool: $tool"
done

work=$(mktemp -d "${TMPDIR:-/tmp}/caihong-mesa.XXXXXX")
trap 'rm -rf -- "$work"' EXIT HUP INT TERM
bsdtar -xf "$bundle" -C "$work"

# Two bundle layouts are understood:
#   * a DESTDIR staging tree with <bundle>/usr/... (built with --prefix=/usr)
#   * a tree installed under a private prefix, <bundle>/lib/aarch64-linux-gnu/...
#     (the original --prefix=/opt/mesa-caihong build)
# The private-prefix layout is only correct when the files really live at that
# prefix at runtime, because libgbm and the Vulkan ICD json contain absolute
# paths. It is therefore installed into /opt/mesa-caihong and made visible with an
# ld.so.conf.d entry that sorts before the system directories.
layout=usr
if [ ! -d "$work/usr/lib" ]; then
	if [ -d "$work/lib/aarch64-linux-gnu" ]; then
		layout=prefix
	else
		die "unexpected bundle layout: neither usr/lib nor lib/aarch64-linux-gnu present"
	fi
fi

if [ "$layout" = prefix ]; then
	prefix=$target/opt/mesa-caihong
	install -d -m 0755 "$prefix"
	rsync -a --chown=0:0 "$work/" "$prefix/"
	install -d -m 0755 "$target/etc/ld.so.conf.d"
	printf '# Caihong Mesa 24.3.4 (private prefix build; sorts before the system dirs)\n/opt/mesa-caihong/lib/aarch64-linux-gnu\n' \
		> "$target/etc/ld.so.conf.d/00-caihong-mesa.conf"
	chmod 0644 "$target/etc/ld.so.conf.d/00-caihong-mesa.conf"
	sample="$prefix/lib/aarch64-linux-gnu/libgallium-24.3.4.so"
else
	sample="$work/usr/lib/aarch64-linux-gnu/libgallium-24.3.4.so"
fi

[ -f "$sample" ] || die "bundle is missing libgallium-24.3.4.so"
machine=$(readelf -h "$sample" 2>/dev/null | awk -F: '/^ *Machine:/ { gsub(/^ +| +$/, "", $2); print $2 }')
[ "$machine" = "AArch64" ] || die "bundle is not an aarch64 build (machine: ${machine:-unknown})"

# A binary that still points at a build prefix crashes at runtime, so refuse it
# instead of shipping a broken GPU stack again.
# Only a bundle meant for the system prefix must be free of build paths; the
# private-prefix layout relies on those paths being installed at that prefix.
if [ "$layout" = usr ]; then
	if grep -qa '/opt/mesa-caihong' "$sample" 2>/dev/null ||
		grep -qa '/opt/mesa-caihong' "$work/usr/lib/aarch64-linux-gnu/libgbm.so.1.0.0" 2>/dev/null; then
		die "bundle contains hardcoded /opt/mesa-caihong paths; rebuild with --prefix=/usr"
	fi
fi

libdir=$target/usr/lib/aarch64-linux-gnu
install -d -m 0755 "$libdir"

note "installing Mesa $(basename "$bundle") into $target"
# The Ubuntu 23.2.1 megadriver and the glvnd vendor copy must not survive next to
# the new stack: the loader would pick whichever the cache resolves first.
rm -f "$libdir"/libgallium-*.so "$libdir"/libEGL_mesa.so.* "$libdir"/libGLESv2_mesa.so.*
# The old per-driver DRI modules belong to 23.2.1; Mesa 24 loads its driver from
# libgallium directly.
if [ -d "$libdir/dri" ]; then
	find "$libdir/dri" -name '*_dri.so' -delete
fi

if [ "$layout" = usr ]; then
	rsync -a --chown=0:0 "$work/usr/" "$target/usr/"
fi

# ldconfig rebuilds soname links from whatever libs it finds, and Ubuntu's glvnd
# libraries declare the same sonames, so pin the links to the Mesa 24 files.
for pair in libEGL.so.1:libEGL.so.1.0.0 libGLESv2.so.2:libGLESv2.so.2.0.0 libgbm.so.1:libgbm.so.1.0.0; do
	link=${pair%%:*}
	dest=${pair#*:}
	[ -f "$libdir/$dest" ] || continue
	ln -sfn "$dest" "$libdir/$link"
done

cat > "$target/usr/share/caihong-mesa.txt" <<EOF
bundle=$(basename "$bundle")
mesa_version=24.3.4
prefix=/usr
gl_renderer=FD750
vulkan_device=Turnip Adreno (TM) 750
gallium_drivers=freedreno
vulkan_drivers=freedreno
platforms=none (console only)
verified_on_device=2026-10-30
reason=Ubuntu 22.04 Mesa 23.2.1 segfaults in the kgsl backend on Adreno 750
EOF
chmod 0644 "$target/usr/share/caihong-mesa.txt"

note "Mesa 24.3.4 installed"
ls -1 "$libdir" | grep -E 'lib(gallium|EGL|GLESv2|gbm|vulkan_freedreno)' || true
