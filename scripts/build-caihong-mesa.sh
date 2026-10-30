#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
#
# Build the Mesa stack that makes the Adreno 750 usable on Ubuntu 22.04.
#
# Ubuntu's Mesa 23.2.1 crashes on this GPU: kmscube/eglinfo/vulkaninfo die with
# SIGSEGV immediately after DRM_IOCTL_MSM_SUBMITQUEUE_NEW, and the crash happens
# in the freedreno kgsl backend regardless of LIBGL_ALWAYS_SOFTWARE, i.e. before
# any shader is compiled. Mesa 24.3.4 works and reports "renderer: FD750" plus
# "Turnip Adreno (TM) 750" for Vulkan.
#
# This must run on an aarch64 Ubuntu 22.04 machine with network access — the
# tablet itself is the simplest host. Cross-building needs arm64 development
# packages that `archive.ubuntu.com` does not serve, so a native build is the
# supported path (see docs/BUILD.zh-CN.md).
#
# usage: sudo scripts/build-caihong-mesa.sh [OUTPUT_DIR]
set -Eeuo pipefail
CDPATH=

VERSION=24.3.4
PREFIX=${PREFIX:-/opt/mesa-caihong}
out=${1:-"$PWD/release"}
export DEBIAN_FRONTEND=noninteractive

log()
{
	printf '==> %s\n' "$*"
}

[ "$(uname -m)" = aarch64 ] || {
	echo "error: this recipe must run natively on aarch64 (see the header)" >&2
	exit 1
}

log "installing build dependencies"
apt-get update -qq
# PyYAML is a Mesa build requirement; jammy's meson (0.61) is too old for Mesa 24.
apt-get install -y -qq build-essential ninja-build pkg-config python3-mako \
	python3-yaml python3-pip bison flex libdrm-dev libexpat1-dev zlib1g-dev \
	libzstd-dev libudev-dev ca-certificates curl
pip3 install --quiet --upgrade 'meson>=1.3'
export PATH=/usr/local/bin:$PATH
meson --version

work=$(mktemp -d "${TMPDIR:-/tmp}/caihong-mesa.XXXXXX")
trap 'rm -rf -- "$work"' EXIT HUP INT TERM
cd "$work"

log "fetching Mesa $VERSION"
curl -fsSL --retry 3 -o "mesa-$VERSION.tar.xz" "https://archive.mesa3d.org/mesa-$VERSION.tar.xz"
sha256sum "mesa-$VERSION.tar.xz"
tar -xf "mesa-$VERSION.tar.xz"
cd "mesa-$VERSION"

log "configuring (freedreno GL + turnip Vulkan + GBM, no window systems)"
meson setup build \
	--buildtype=release \
	--prefix="$PREFIX" \
	-Dplatforms= \
	-Dgallium-drivers=freedreno \
	-Dvulkan-drivers=freedreno \
	-Dfreedreno-kmds=kgsl,msm \
	-Dglx=disabled \
	-Dglvnd=disabled \
	-Degl=enabled \
	-Dgles1=disabled \
	-Dgles2=enabled \
	-Dgbm=enabled \
	-Dopengl=true \
	-Dllvm=disabled \
	-Dlibunwind=disabled \
	-Dzstd=enabled \
	-Dvideo-codecs= \
	-Dstrip=true

log "building"
ninja -C build -j"$(nproc)"
ninja -C build install

log "packaging"
mkdir -p "$out"
tar -cf - -C "$PREFIX" . | zstd -q -T0 -10 -o "$out/caihong-mesa-$VERSION-aarch64.tar.zst" --force
sha256sum "$out/caihong-mesa-$VERSION-aarch64.tar.zst"
log "install into a rootfs with: scripts/install-caihong-mesa.sh <bundle> <rootfs>"
