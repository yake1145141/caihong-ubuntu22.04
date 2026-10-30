#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
#
# Build an Ubuntu 22.04 LTS (Jammy) arm64 root filesystem for the OnePlus Pad
# Pro (caihong) from the official ubuntu-ports archives.
#
# The device has no bootloader-side initramfs: the Caihong boot image carries
# only the kernel Image and the device tree, and the kernel mounts its root
# filesystem straight from UFS. ext4 and the Qualcomm UFS host controller are
# therefore built into the kernel (asserted by scripts/prepare-caihong-kernel.sh)
# and this rootfs intentionally ships no initramfs.
#
# usage: sudo scripts/build-ubuntu-rootfs.sh [TARGET_DIR]
#
# Output is a plain rootfs tree; scripts/build-ubuntu-image.sh turns it into the
# sparse ext4 image that is flashed to the "linux" or "userdata" partition.
set -Eeuo pipefail
CDPATH=

project_dir=$(cd -- "$(dirname -- "$0")/.." && pwd)
# shellcheck source=config/ubuntu.env
. "$project_dir/config/ubuntu.env"

target=${1:-"$project_dir/build/rootfs"}
kernel_dir=${KERNEL_OUT:-"$project_dir/build/kernel"}
overlay="$project_dir/rootfs/ubuntu"
reference_overlay="$project_dir/rootfs/archlinuxarm"
firmware_tree="$project_dir/firmware"
ssc_bundle=${SSC_BUNDLE:-"$project_dir/firmware-assets/caihong-ssc"}
install_ssc=${INSTALL_SSC:-auto}
work_dir=

die()
{
	printf 'error: %s\n' "$*" >&2
	exit 1
}

note()
{
	printf '%s\n' "$*"
}

unmount_target()
{
	local api
	for api in run dev/pts dev proc sys; do
		if mountpoint -q "$target/$api" 2>/dev/null; then
			umount --lazy "$target/$api" 2>/dev/null || return 1
		fi
	done
	return 0
}

cleanup()
{
	status=$?
	trap - EXIT HUP INT TERM
	unmount_target || true
	if [ -n "$work_dir" ] && [ -d "$work_dir" ]; then
		rm -rf -- "$work_dir"
	fi
	exit "$status"
}
trap cleanup EXIT HUP INT TERM

[ "$(id -u)" -eq 0 ] || die "run as root: debootstrap and file ownership require it"

case $(uname -m) in
	aarch64|arm64) native_aarch64=1 ;;
	*) native_aarch64=0 ;;
esac

for tool in debootstrap rsync curl sha256sum chroot findmnt mountpoint; do
	command -v "$tool" >/dev/null 2>&1 || die "missing host tool: $tool"
done
if (( ! native_aarch64 )); then
	command -v qemu-aarch64-static >/dev/null 2>&1 ||
		die "cross build needs qemu-aarch64-static (apt install qemu-user-static binfmt-support)"
fi

[ -d "$kernel_dir/lib/modules" ] ||
	die "prepared kernel not found in $kernel_dir; run scripts/prepare-caihong-kernel.sh first"
kernel_release=
for candidate in "$kernel_dir"/lib/modules/*; do
	[ -d "$candidate" ] || continue
	if [ -n "$kernel_release" ]; then
		die "more than one kernel release in $kernel_dir/lib/modules"
	fi
	kernel_release=${candidate##*/}
done
[ -n "$kernel_release" ] || die "no kernel release in $kernel_dir/lib/modules"
[ "$kernel_release" = "$KERNEL_RELEASE" ] ||
	die "prepared kernel is $kernel_release, config/ubuntu.env pins $KERNEL_RELEASE"

[ -d "$firmware_tree" ] || die "missing firmware tree: $firmware_tree"
(cd "$firmware_tree" && sha256sum -c SHA256SUMS >/dev/null) ||
	die "Caihong firmware failed its own SHA256SUMS check"
for artifact in Image caihong.dtb; do
	[ -f "$kernel_dir/$artifact" ] || die "missing $kernel_dir/$artifact"
done

case "$target" in
	/|/boot|/home|/usr|/var|/etc) die "refusing unsafe target: $target" ;;
esac
mkdir -p "$target" "$project_dir/build"
target=$(cd -- "$target" && pwd)

# RESUME=1 keeps an already bootstrapped tree so that iterating on the package set
# does not pay for a full debootstrap run again. The base system is validated
# before it is trusted.
resume=0
if [ "${RESUME:-0}" = 1 ] && [ -f "$target/etc/os-release" ] &&
	[ -f "$target/var/lib/dpkg/status" ] &&
	grep -q '^ID=ubuntu' "$target/etc/os-release"; then
	resume=1
	note "=== resuming the existing Ubuntu base system in $target"
fi

if [ "$resume" = 0 ] && [ -n "$(find "$target" -mindepth 1 -maxdepth 1 -print -quit)" ]; then
	[ "${FORCE:-0}" = 1 ] || die "target is not empty: $target (set FORCE=1 to rebuild it)"
	note "clearing $target"
	find "$target" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
fi

root_partlabel=${ROOT_PARTLABEL:-$ROOTFS_LABEL_DUALBOOT}
case "$root_partlabel" in
	"$ROOTFS_LABEL_DUALBOOT"|"$ROOTFS_LABEL_SINGLE") ;;
	*) die "unsupported root partition label: $root_partlabel" ;;
esac

work_dir=$(mktemp -d "$project_dir/build/ubuntu-rootfs.XXXXXX")

mirror=${UBUNTU_MIRROR%/}
# debootstrap wants a comma-separated component list, sources.list wants spaces:
# a single "main,universe,..." token silently matches no component at all.
components=$UBUNTU_COMPONENTS
sources_components=${UBUNTU_COMPONENTS//,/ }

if [ "$resume" = 0 ]; then
	note "=== stage 1: debootstrap $UBUNTU_SUITE/$UBUNTU_ARCH from $mirror"
	debootstrap_args=(
		--arch="$UBUNTU_ARCH"
		--variant=minbase
		--components="$components"
		--include=apt,ca-certificates,ubuntu-keyring
	)
	if (( native_aarch64 )); then
		debootstrap "${debootstrap_args[@]}" "$UBUNTU_SUITE" "$target" "$mirror"
	else
		debootstrap "${debootstrap_args[@]}" --foreign "$UBUNTU_SUITE" "$target" "$mirror"
	fi
fi

# debootstrap only writes the release entry. The device needs updates and
# security as well, and arm64 packages live on ubuntu-ports.
cat > "$target/etc/apt/sources.list" <<EOF
# Caihong Ubuntu $UBUNTU_SUITE ($UBUNTU_ARCH). arm64 packages live on the
# ubuntu-ports archive; archive.ubuntu.com does not carry them.
deb $mirror $UBUNTU_SUITE $sources_components
deb $mirror $UBUNTU_UPDATES_SUITE $sources_components
deb ${UBUNTU_SECURITY_MIRROR%/} $UBUNTU_SECURITY_SUITE $sources_components
EOF

# Maintainer scripts must never start daemons on the build host.
cat > "$target/usr/sbin/policy-rc.d" <<'EOF'
#!/bin/sh
# Caihong rootfs build: units are enabled here and started on the device only.
exit 101
EOF
chmod 0755 "$target/usr/sbin/policy-rc.d"

if [ "$resume" = 0 ] && (( ! native_aarch64 )); then
	note "=== stage 2: unpacking the base system under qemu-aarch64"
	install -D -m 0755 "$(command -v qemu-aarch64-static)" "$target/usr/bin/qemu-aarch64-static"
	chroot "$target" /debootstrap/debootstrap --second-stage
	rm -f -- "$target/usr/bin/qemu-aarch64-static"
fi

# An interrupted earlier run can leave lazy mounts behind; start from a clean
# state so the maintainer scripts always see a complete /dev, including /dev/pts.
for api in run dev/pts dev proc sys; do
	mountpoint -q "$target/$api" 2>/dev/null && umount --lazy "$target/$api" 2>/dev/null || true
done
for api in proc sys dev dev/pts; do
	mkdir -p "$target/$api"
	mount --bind "/$api" "$target/$api"
	mount --make-private "$target/$api"
done
mkdir -p "$target/run"
mount -t tmpfs -o mode=0755,nosuid,nodev tmpfs "$target/run"
# The finished image points /etc/resolv.conf at systemd-resolved, so on a resumed
# tree it is a dangling symlink and cp would refuse to write through it.
rm -f -- "$target/etc/resolv.conf"
cp -L /etc/resolv.conf "$target/etc/resolv.conf"
if (( ! native_aarch64 )); then
	install -D -m 0755 "$(command -v qemu-aarch64-static)" "$target/usr/bin/qemu-aarch64-static"
fi

run_in_target()
{
	chroot "$target" /usr/bin/env -i \
		HOME=/root \
		LANG=C.UTF-8 \
		LC_ALL=C.UTF-8 \
		PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
		DEBIAN_FRONTEND=noninteractive \
		SYSTEMD_OFFLINE=1 \
		"$@"
}

note "=== installing the Ubuntu Server package set"
# debootstrap installs its base system without populating the apt lists, so the
# first apt-get inside the chroot would not find even "systemd".
run_in_target apt-get update -q >/dev/null ||
	die "apt-get update failed inside the rootfs; check $mirror connectivity"
# A resumed build may have been interrupted inside dpkg; finish that transaction
# before starting a new one.
run_in_target dpkg --configure -a >/dev/null 2>&1 || true
# Deliberately enumerated: no ubuntu-server metapackage, no linux-image (the
# kernel arrives through the Android boot image), no initramfs-tools, and no
# generic linux-firmware (the Caihong firmware tree replaces it below).
packages=(
	# init, package management, console
	systemd systemd-sysv udev dbus libpam-systemd systemd-timesyncd
	apt dpkg debconf adduser passwd login util-linux mount kmod procps psmisc
	e2fsprogs dosfstools parted gdisk fdisk
	console-setup kbd locales tzdata sudo
	bash coreutils findutils grep sed gawk tar gzip xz-utils zstd file less nano
	ca-certificates gnupg curl wget rsync
	# networking and remote access
	openssh-server network-manager wpasupplicant iw rfkill dnsmasq-base nftables
	iproute2 iputils-ping netbase ethtool tcpdump socat
	# USB and Type-C
	usbutils usb-modeswitch libusb-1.0-0
	# hardware inspection and diagnostics
	pciutils i2c-tools evtest v4l-utils alsa-utils alsa-ucm-conf strace lsof htop
	# bluetooth
	bluez
	# GPU / DRM user space: freedreno + turnip from jammy-updates (mesa 23.2.1)
	libgl1-mesa-dri libglapi-mesa libegl1 libegl-mesa0 libgles2 libgbm1 libdrm2
	mesa-vulkan-drivers mesa-utils vulkan-tools kmscube glmark2-es2
	# Android sparse image tools (simg2img/img2simg) for on-device work
	android-sdk-libsparse-utils
	# scripting used by the Caihong board services
	python3 python3-gi
)

# Packages that improve the image when the archive provides them, but are not
# required for booting. Ubuntu 22.04 ships no adbd and no arm64
# iio-sensor-proxy in every pocket; a missing probe tool must not abort an
# otherwise valid build.
optional_packages=(
	iio-sensor-proxy lm-sensors upower cpufrequtils usb-modeswitch
)
optional_installed=()

# One apt-get invocation: each call re-reads the package lists, which is the
# dominant cost under qemu-user. Fall back to one-at-a-time only when the bulk
# transaction fails, so a failure still names the offending package.
if ! run_in_target apt-get install -y -q --no-install-recommends "${packages[@]}" >/dev/null; then
	note "bulk install failed; retrying one package at a time to find the culprit"
	for package in "${packages[@]}"; do
		run_in_target apt-get install -y -q --no-install-recommends "$package" >/dev/null ||
			die "apt-get install failed for $package"
	done
fi
note "installed ${#packages[@]} requested packages"

for package in "${optional_packages[@]}"; do
	if run_in_target apt-get install -y -q --no-install-recommends "$package" >/dev/null 2>&1; then
		optional_installed+=("$package")
	else
		note "optional package unavailable on $UBUNTU_SUITE/$UBUNTU_ARCH: $package"
	fi
done
[ ${#optional_installed[@]} -eq 0 ] ||
	note "installed optional: ${optional_installed[*]}"

note "=== configuring the base system"
echo "$CAIHONG_HOSTNAME" > "$target/etc/hostname"
cat > "$target/etc/hosts" <<EOF
127.0.0.1	localhost
127.0.1.1	$CAIHONG_HOSTNAME

::1	localhost ip6-localhost ip6-loopback
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
EOF

for locale in $CAIHONG_LOCALES; do
	grep -qx "$locale UTF-8" "$target/etc/locale.gen" ||
		echo "$locale UTF-8" >> "$target/etc/locale.gen"
done
run_in_target locale-gen >/dev/null
echo 'LANG=en_US.UTF-8' > "$target/etc/default/locale"
ln -sfn "/usr/share/zoneinfo/$CAIHONG_TIMEZONE" "$target/etc/localtime"
echo "$CAIHONG_TIMEZONE" > "$target/etc/timezone"

# The internal panel is 3000x2120: the stock 8x16 VGA font is unreadable there,
# so select the largest Terminus console font the archive ships.
cat > "$target/etc/default/console-setup" <<'EOF'
# Managed by the Caihong Ubuntu rootfs builder.
ACTIVE_CONSOLES="/dev/tty[1-6]"
CHARMAP="UTF-8"
CODESET="Lat15"
FONTFACE="Terminus"
FONTSIZE="16x32"
EOF

# systemd-firstboot would put an interactive prompt on the panel console before
# any login; everything it asks for is already baked into the image.
ln -sfn /dev/null "$target/etc/systemd/system/systemd-firstboot.service"

cat > "$target/etc/fstab" <<EOF
# Managed by the Caihong Ubuntu rootfs builder.
PARTLABEL=$root_partlabel	/	ext4	rw,noatime,errors=remount-ro	0	1
proc	/proc	proc	defaults	0	0
sysfs	/sys	sysfs	defaults	0	0
devpts	/dev/pts	devpts	gid=5,mode=620	0	0
tmpfs	/dev/shm	tmpfs	defaults,mode=1777,nosuid,nodev	0	0
tmpfs	/tmp	tmpfs	defaults,nosuid,nodev,mode=1777	0	0
EOF

note "=== installing Caihong firmware"
rm -rf -- "$target/usr/lib/firmware"
install -d -m 0755 "$target/usr/lib/firmware"
rsync -a --exclude=SOURCE.md --exclude=SHA256SUMS \
	"$firmware_tree/." "$target/usr/lib/firmware/"
# The AudioReach topology is generated from the vendored m4 sources, exactly as
# the reference rootfs does, so the blob matches this kernel's ASoC drivers.
# alsatplg comes from alsa-utils on the build host; without it the SHA-256
# verified copy that ships in firmware/ is still correct for this release.
if command -v alsatplg >/dev/null 2>&1 || [ -n "${ALSATPLG:-}" ]; then
	"$project_dir/scripts/build-caihong-audioreach-topology.sh" \
		"$target/usr/lib/firmware/qcom/sm8650/SM8650-MTP-tplg.bin" ||
		note "warning: topology generation failed; keeping the packaged SM8650-MTP-tplg.bin"
else
	note "warning: alsatplg is unavailable; keeping the packaged SM8650-MTP-tplg.bin"
fi

note "=== installing the matching Caihong kernel modules"
rm -rf -- "$target/lib/modules"
install -d -m 0755 "$target/lib/modules"
rsync -aHAX --numeric-ids "$kernel_dir/lib/modules/$kernel_release" \
	"$target/lib/modules/"
[ -s "$target/lib/modules/$kernel_release/modules.dep" ] ||
	die "module dependency metadata did not survive the copy"

note "=== applying the Caihong board overlay"
# Distribution-neutral board policy from the reference tree: module list,
# udev rules, NetworkManager tuning, ALSA UCM, shutdown timeouts and the systemd
# units for the pen, hotspot, hardware MAC, ADB and root-growth services.
copy_reference()
{
	local relative=$1
	local source="$reference_overlay/$relative"
	local destination="$target/$relative"
	[ -d "$source" ] || return 0
	install -d -m 0755 "$destination"
	rsync -a --chown=0:0 "$source/" "$destination/"
}
copy_reference usr/lib/systemd/system
copy_reference usr/lib/udev/rules.d
copy_reference usr/lib/tmpfiles.d
copy_reference etc/udev/rules.d
copy_reference etc/modules-load.d
copy_reference etc/NetworkManager
copy_reference etc/bluetooth
copy_reference etc/systemd
copy_reference usr/share/alsa/ucm2

# The board services (pen pairing, hotspot, hardware MAC, A/B slot handling) are
# POSIX shell that only needs nmcli/bluetoothctl/nft/iw. Reuse the reference
# implementations rather than forking them, so fixes do not diverge.
install -d -m 0755 "$target/usr/local/sbin" "$target/usr/local/libexec"
for script in "$reference_overlay"/usr/local/sbin/*; do
	[ -f "$script" ] || continue
	case ${script##*/} in
		caihong-fix-kwin-brightness|caihong-clean-pogo-kde)
			# KDE-only helpers; meaningless on a Server image.
			continue
			;;
	esac
	install -m 0755 "$script" "$target/usr/local/sbin/${script##*/}"
done

# Ubuntu-specific overrides win over every reference copy, including the shell
# implementations installed just above (adbd supervision, root growth).
rsync -aHAX --numeric-ids --chown=0:0 "$overlay/" "$target/"

# The overlay can come from a Windows working tree, where every file is 0777.
# systemd refuses to load a world-writable unit and warns about an executable
# one, so normalise the overlay's metadata deterministically.
find "$target/etc/systemd" "$target/etc/NetworkManager" -type f -exec chmod 0644 {} +
find "$target/usr/local/sbin" "$target/usr/local/libexec" -type f -exec chmod 0755 {} +
# A debug key must never be baked into a released image implicitly: it is only
# installed when the builder asks for it, and the file is copied with the exact
# permissions sshd requires.
if [ -n "${CAIHONG_DEBUG_KEY_FILE:-}" ]; then
	[ -f "$CAIHONG_DEBUG_KEY_FILE" ] ||
		die "CAIHONG_DEBUG_KEY_FILE does not exist: $CAIHONG_DEBUG_KEY_FILE"
	install -d -m 0700 "$target/root/.ssh"
	install -m 0600 "$CAIHONG_DEBUG_KEY_FILE" "$target/root/.ssh/authorized_keys"
	note "installed the debug SSH key from $CAIHONG_DEBUG_KEY_FILE"
	note "warning: remove it from the device with 'rm /root/.ssh/authorized_keys' when done"
else
	# A resumed tree may still carry a key from an earlier debug build; a release
	# image must never contain one.
	rm -rf -- "$target/root/.ssh"
fi

note "=== building the Caihong userspace helpers"
# A compiler is only needed to build two small probe binaries and qbootctl; it is
# removed again so the shipped image stays a server image.
run_in_target apt-get install -y -q --no-install-recommends \
	gcc libc6-dev libssl-dev pkg-config meson ninja-build libglib2.0-dev >/dev/null ||
	note "warning: cannot install the helper build toolchain; A/B and MAC helpers will be skipped"

helpers_ok=0
if [ -x "$target/usr/bin/gcc" ]; then
	helpers_ok=1
fi
if [ "$helpers_ok" = 1 ]; then
	for tool in caihong-nvram-mac caihong-npu-info; do
		src="$project_dir/tools/$tool.c"
		[ -f "$src" ] || continue
		install -m 0644 "$src" "$target/tmp/$tool.c"
		case "$tool" in
			caihong-nvram-mac)
				run_in_target gcc -O2 -Wall -Wextra -Werror -o \
					/usr/local/libexec/caihong-nvram-mac "/tmp/$tool.c" -lcrypto >/dev/null 2>&1 ||
					note "warning: cannot build $tool (needs OpenSSL headers)"
				;;
			caihong-npu-info)
				run_in_target gcc -O2 -Wall -Wextra -Werror -o \
					/usr/local/sbin/caihong-npu-info "/tmp/$tool.c" -ldl >/dev/null 2>&1 ||
					note "warning: cannot build $tool"
				;;
		esac
		rm -f -- "$target/tmp/$tool.c"
	done

	if [ -f "$project_dir/external/qbootctl/meson.build" ]; then
		rsync -a --exclude=.git --exclude=build "$project_dir/external/qbootctl/" \
			"$target/tmp/qbootctl/"
		if run_in_target meson setup /tmp/qbootctl/build /tmp/qbootctl \
			--buildtype=release --prefix=/usr/local --bindir=sbin >/dev/null 2>&1 &&
			run_in_target meson compile -C /tmp/qbootctl/build >/dev/null 2>&1 &&
			run_in_target meson install -C /tmp/qbootctl/build --no-rebuild >/dev/null 2>&1; then
			note "qbootctl installed"
		else
			note "warning: qbootctl build failed; A/B slot helpers stay disabled"
		fi
		rm -rf -- "$target/tmp/qbootctl"
	fi

	run_in_target apt-get purge -y -q gcc libc6-dev libssl-dev pkg-config meson \
		ninja-build libglib2.0-dev >/dev/null 2>&1 || true
	run_in_target apt-get autoremove -y -q >/dev/null 2>&1 || true
fi
rm -rf -- "$target/tmp/caihong-packages"

note "=== installing the Caihong SSC sensor stack"
# The published SSC bundle was linked against glibc 2.38. Enable it only when the
# Jammy loader can actually run it, otherwise ship a sensor-free image and say so
# instead of enabling a unit that cannot start.
ssc_state=skipped
if [ "$install_ssc" != 0 ] && [ -d "$ssc_bundle" ]; then
	if reason=$("$project_dir/scripts/check-aarch64-glibc.sh" \
		--max-glibc 2.35 "$ssc_bundle/bin/iio-sensor-proxy" \
		"$ssc_bundle/bin/hexagonrpcd" "$ssc_bundle/lib/libssc.so.2" \
		"$ssc_bundle/lib/libhexagonrpc.so.0.5" 2>&1); then
		"$project_dir/scripts/ssc/install-rootfs.sh" "$ssc_bundle" "$target"
		ssc_state=installed
		note "SSC sensor stack installed"
	else
		note "warning: SCC bundle needs a newer glibc than Jammy provides; skipping sensors"
		printf '         %s\n' "$reason"
		ssc_state=incompatible-glibc
	fi
elif [ "$install_ssc" = 1 ]; then
	die "INSTALL_SSC=1 but no bundle at $ssc_bundle"
fi

note "=== configuring accounts and remote access"
echo "root:$CAIHONG_DEFAULT_ROOT_PASSWORD" | chroot "$target" chpasswd
if ! chroot "$target" id "$CAIHONG_DEFAULT_USER" >/dev/null 2>&1; then
	chroot "$target" useradd -m -s /bin/bash -G sudo,dialout,plugdev,audio,input,video,render,netdev \
		"$CAIHONG_DEFAULT_USER"
fi
echo "$CAIHONG_DEFAULT_USER:$CAIHONG_DEFAULT_USER_PASSWORD" | chroot "$target" chpasswd
chroot "$target" passwd -u root >/dev/null 2>&1 || true

install -d -m 0755 "$target/etc/ssh/sshd_config.d"
cat > "$target/etc/ssh/sshd_config.d/10-caihong.conf" <<'EOF'
# Managed by the Caihong Ubuntu rootfs builder. The tablet has no serial console,
# so password login is the documented recovery path until keys are installed.
PermitRootLogin yes
PasswordAuthentication yes
KbdInteractiveAuthentication yes
EOF

note "=== enabling units"
systemctl --root="$target" enable ssh.service >/dev/null 2>&1 ||
	die "cannot enable ssh.service"
for unit in network-manager.service systemd-resolved.service systemd-timesyncd.service \
	bluetooth.service console-setup.service keyboard-setup.service; do
	[ -e "$target/lib/systemd/system/$unit" ] || [ -e "$target/usr/lib/systemd/system/$unit" ] || continue
	systemctl --root="$target" enable "$unit" >/dev/null 2>&1 || true
done
for unit in caihong-grow-rootfs.service caihong-mark-boot-successful.service \
	caihong-bluetooth-autostart.service caihong-hardware-mac.service \
	caihong-adbd.service caihong-hotspot.service caihong-ssc.service \
	caihong-usbnet.service caihong-boot-status.service \
	caihong-pen-autoconnect.timer caihong-pen-charge.timer caihong-pen-pair.timer; do
	if [ -f "$target/etc/systemd/system/$unit" ] || [ -f "$target/usr/lib/systemd/system/$unit" ]; then
		systemctl --root="$target" enable "$unit" >/dev/null 2>&1 ||
			note "warning: cannot enable $unit"
		# caihong-hotspot and caihong-ssc are started on demand, not at boot.
		case "$unit" in
			caihong-hotspot.service|caihong-ssc.service)
				systemctl --root="$target" disable "$unit" >/dev/null 2>&1 || true
				;;
		esac
	fi
done
systemctl --root="$target" set-default multi-user.target >/dev/null 2>&1 || true

# The internal panel shows tty1. Newer Ubuntu images enable it, but never assume.
install -d -m 0755 "$target/etc/systemd/system/getty.target.wants"
ln -sfn /usr/lib/systemd/system/getty@.service \
	"$target/etc/systemd/system/getty.target.wants/getty@tty1.service"

# systemd-resolved owns the resolver on Ubuntu; a static file would hide DHCP
# results from applications.
rm -f -- "$target/etc/resolv.conf"
ln -sfn ../run/systemd/resolve/stub-resolv.conf "$target/etc/resolv.conf"

note "=== installing the Caihong Mesa stack (GPU user space)"
# Ubuntu 22.04's Mesa 23.2.1 crashes in the freedreno kgsl backend on Adreno 750
# (SIGSEGV right after DRM_IOCTL_MSM_SUBMITQUEUE_NEW). The bundle below is the
# Mesa 24.3.4 build that was validated on the device.
mesa_bundle=${CAIHONG_MESA_BUNDLE:-}
if [ -z "$mesa_bundle" ]; then
	for candidate in "$project_dir"/vendor/mesa/*.tar.zst; do
		[ -f "$candidate" ] || continue
		mesa_bundle=$candidate
		break
	done
fi
if [ -n "$mesa_bundle" ]; then
	"$project_dir/scripts/install-caihong-mesa.sh" "$mesa_bundle" "$target" ||
		die "cannot install the Mesa bundle: $mesa_bundle"
else
	note "warning: no Mesa bundle found in vendor/mesa; the image keeps Ubuntu's"
	note "         Mesa 23.2.1, which crashes on Adreno 750 (GPU acceleration will NOT work)"
fi


note "=== cleaning up build state"
rm -f -- "$target/usr/bin/qemu-aarch64-static" "$target/usr/sbin/policy-rc.d"
run_in_target apt-get clean >/dev/null 2>&1 || true
rm -rf "$target"/var/lib/apt/lists/* "$target"/var/cache/apt/archives/*.deb \
	"$target"/var/lib/apt/lists/partial
: > "$target/etc/machine-id"
rm -f "$target"/etc/ssh/ssh_host_*
rm -rf "$target"/var/log/journal/*
install -d -m 0700 "$target/root"
rm -f -- "$target/root/.bash_history"

cat > "$target/etc/caihong-rootfs-build-info" <<EOF
device=caihong
distribution=ubuntu
distribution_release=$UBUNTU_SUITE
architecture=$UBUNTU_ARCH
package_mirror=$mirror
kernel_release=$kernel_release
kernel_image_sha256=$(sha256sum "$kernel_dir/Image" | awk '{ print $1 }')
kernel_dtb_sha256=$(sha256sum "$kernel_dir/caihong.dtb" | awk '{ print $1 }')
boot_roots=PARTLABEL=$ROOTFS_LABEL_DUALBOOT,PARTLABEL=$ROOTFS_LABEL_SINGLE
root_partlabel=$root_partlabel
boot_kernel=android-boot-v2-direct-root
boot_ramdisk=none
initramfs=none
ssc=$ssc_state
firmware_source=reference-linux-caihong-release
built_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
chmod 0644 "$target/etc/caihong-rootfs-build-info"

# Record the installed package set so two builds can be diffed.
chroot "$target" dpkg-query -W -f='${Package} ${Version} ${Architecture}\n' \
	> "$target/etc/caihong-packages.txt"
sort -o "$target/etc/caihong-packages.txt" "$target/etc/caihong-packages.txt"

unmount_target || die "cannot unmount the API filesystems below $target"

note ""
note "Ubuntu $UBUNTU_SUITE rootfs ready at $target"
du -sh "$target" | awk '{ print "size: " $1 }'
note "root partition label: $root_partlabel"
note "kernel: $kernel_release, no initramfs, direct ext4 root"
note "sensors (SSC): $ssc_state"
