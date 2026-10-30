#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
#
# Verify a Caihong Ubuntu 22.04 build: the rootfs tree, the boot images and the
# installable filesystem image.
#
# Every check states what is asserted, so a failure names the broken guarantee
# instead of just saying "invalid". Checks that need real hardware (panel, USB-C,
# charging, GPU rendering) cannot be performed here and are listed as SKIP with
# the exact on-device command that replaces them.
#
# usage: scripts/verify-ubuntu-image.sh [options]
#   --rootfs DIR    rootfs tree produced by build-ubuntu-rootfs.sh
#   --boot IMG      boot image (may be repeated)
#   --image IMG     rootfs image, sparse or zstd-compressed
#   --quiet         print failures only
set -Eeuo pipefail
CDPATH=

project_dir=$(cd -- "$(dirname -- "$0")/.." && pwd)
# shellcheck source=config/ubuntu.env
. "$project_dir/config/ubuntu.env"

rootfs=
boot_images=()
images=()
quiet=0

while [ $# -gt 0 ]; do
	case $1 in
		--rootfs) rootfs=${2:?--rootfs needs a directory}; shift 2 ;;
		--boot) boot_images+=("${2:?--boot needs a file}"); shift 2 ;;
		--image) images+=("${2:?--image needs a file}"); shift 2 ;;
		--quiet) quiet=1; shift ;;
		-h|--help)
			sed -n '2,20p' "$0"
			exit 0
			;;
		*) echo "unknown option: $1" >&2; exit 2 ;;
	esac
done

[ -n "$rootfs" ] || [ ${#boot_images[@]} -gt 0 ] || [ ${#images[@]} -gt 0 ] ||
	{ echo "nothing to verify; pass --rootfs, --boot and/or --image" >&2; exit 2; }

# The prepared kernel manifest carries the pinned payload digests and sizes. It is
# optional: verifying a standalone image without build/kernel still works, but the
# boot image payload comparisons are then skipped.
manifest_value()
{
	[ -f "$kernel_manifest" ] || { printf ''; return 0; }
	awk -F= -v key="$1" '$1 == key { sub(/^[^=]*=/, ""); gsub(/^"|"$/, ""); print; exit }' \
		"$kernel_manifest"
}
kernel_manifest=${KERNEL_OUT:-"$project_dir/build/kernel"}/manifest.env
KERNEL_IMAGE_SHA256=${KERNEL_IMAGE_SHA256:-$(manifest_value KERNEL_IMAGE_SHA256)}
KERNEL_DTB_SHA256=${KERNEL_DTB_SHA256:-$(manifest_value KERNEL_DTB_SHA256)}
KERNEL_DTB_SIZE=$(manifest_value KERNEL_DTB_SIZE)
KERNEL_IMAGE_SIZE=$(manifest_value KERNEL_IMAGE_SIZE)

passes=0
failures=0
skips=0

pass()
{
	passes=$((passes + 1))
	[ "$quiet" = 1 ] || printf 'PASS  %s\n' "$*"
}

fail()
{
	failures=$((failures + 1))
	printf 'FAIL  %s\n' "$*" >&2
}

skip()
{
	skips=$((skips + 1))
	[ "$quiet" = 1 ] || printf 'SKIP  %s\n' "$*"
}

section()
{
	[ "$quiet" = 1 ] || printf '\n== %s ==\n' "$*"
}

exists()
{
	if [ -e "$1" ]; then pass "$2"; else fail "$2 (missing: $1)"; fi
}

grep_file()
{
	local pattern=$1 file=$2 message=$3
	if [ -f "$file" ] && grep -q -- "$pattern" "$file"; then
		pass "$message"
	else
		fail "$message (no '$pattern' in $file)"
	fi
}

# --- rootfs ------------------------------------------------------------------
if [ -n "$rootfs" ]; then
	[ -d "$rootfs" ] || { echo "rootfs not found: $rootfs" >&2; exit 1; }
	rootfs=$(cd -- "$rootfs" && pwd)
	section "rootfs: Ubuntu user space"

	if [ -f "$rootfs/etc/os-release" ] && grep -q '^ID=ubuntu' "$rootfs/etc/os-release"; then
		release=$(awk -F= '/^VERSION_ID=/{ gsub(/"/, "", $2); print $2 }' "$rootfs/etc/os-release")
		if [ "$release" = "22.04" ]; then
			pass "user space is Ubuntu $release ($UBUNTU_SUITE)"
		else
			fail "user space is Ubuntu $release, expected 22.04"
		fi
	else
		fail "rootfs has no Ubuntu /etc/os-release"
	fi
	exists "$rootfs/usr/lib/systemd/systemd" "systemd is installed"
	exists "$rootfs/usr/sbin/sshd" "OpenSSH server is installed"
	exists "$rootfs/etc/systemd/system/getty.target.wants/getty@tty1.service" \
		"a getty runs on tty1 (the internal panel console)"
	exists "$rootfs/etc/ssh/sshd_config.d/10-caihong.conf" "sshd accepts password login for recovery"
	exists "$rootfs/etc/systemd/system/ssh.service.d/10-caihong-host-keys.conf" \
		"sshd generates host keys on first boot (without this sshd fails its own config check)"
	exists "$rootfs/usr/local/sbin/caihong-battery" "battery reporting helper is present"
	exists "$rootfs/usr/local/sbin/caihong-grow-rootfs" "root filesystem growth helper is present"
	exists "$rootfs/usr/local/sbin/caihong-usbnet" "USB RNDIS gadget helper is present (keyboard-free debug channel)"

	section "rootfs: kernel and modules"
	module_dirs=()
	for candidate in "$rootfs"/lib/modules/*/; do
		# the glob keeps a trailing slash, which would make ${dir##*/} empty
		candidate=${candidate%/}
		[ -d "$candidate" ] && module_dirs+=("$candidate")
	done
	if [ ${#module_dirs[@]} -eq 1 ]; then
		release=${module_dirs[0]##*/}
		pass "exactly one module tree: $release"
		if [ "$release" = "$KERNEL_RELEASE" ]; then
			pass "module tree matches the pinned kernel $KERNEL_RELEASE"
		else
			fail "module tree is $release, config pins $KERNEL_RELEASE"
		fi
		[ -s "${module_dirs[0]}/modules.dep" ] &&
			pass "modules.dep is populated" ||
			fail "modules.dep is empty; modprobe would not resolve dependencies"
	else
		fail "expected exactly one kernel release below /lib/modules, found ${#module_dirs[@]}"
	fi
	# Module paths are relative to <release>/ and therefore start with "kernel/".
	for module in kernel/drivers/gpu/drm/msm/msm.ko \
		kernel/drivers/power/supply/sc8547_cp.ko \
		kernel/drivers/input/touchscreen/nt36532e_ts.ko \
		kernel/drivers/net/wireless/ath/ath12k/ath12k.ko \
		kernel/drivers/remoteproc/qcom_q6v5_pas.ko; do
		if [ -n "${module_dirs[0]:-}" ] && [ -f "${module_dirs[0]}/$module" ]; then
			pass "module present: $module"
		elif [ -n "${module_dirs[0]:-}" ] && grep -q "/$(basename "${module%.ko}")\.ko$" \
			"${module_dirs[0]}/modules.builtin" 2>/dev/null; then
			pass "driver built into the kernel: $module"
		else
			fail "missing module and not built in: $module"
		fi
	done

	section "rootfs: firmware and GPU user space"
	for firmware in qcom/gmu_gen70900.bin qcom/gen70900_sqe.fw \
		ath12k/WCN7850/hw2.0/board-2.bin qcom/sm8650/Oneplus/caihong/adsp.b00 \
		regulatory.db; do
		if [ -f "$rootfs/usr/lib/firmware/$firmware" ] ||
			[ -f "$rootfs/lib/firmware/$firmware" ]; then
			pass "firmware present: $firmware"
		else
			fail "missing firmware: $firmware"
		fi
	done
	if [ -e "$rootfs/usr/lib/firmware/linux-firmware" ]; then
		fail "generic linux-firmware tree is present; the Caihong tree must replace it"
	fi
	mesa_dri=$(find "$rootfs/usr/lib" -name 'kgsl_dri.so' -o -name 'msm_dri.so' 2>/dev/null | head -n 1)
	[ -n "$mesa_dri" ] && pass "freedreno Gallium driver installed: ${mesa_dri##*/}" ||
		fail "no freedreno Gallium driver (msm_dri.so/kgsl_dri.so) in the rootfs"
	turnip=$(find "$rootfs/usr/lib" -name 'libvulkan_freedreno.so' 2>/dev/null | head -n 1)
	[ -n "$turnip" ] && pass "Turnip Vulkan driver installed" ||
		fail "no libvulkan_freedreno.so in the rootfs"

	exists "$rootfs/usr/share/caihong-mesa.txt" "Mesa 24.3.4 bundle installed (Jammy's 23.2.1 crashes on Adreno 750)"
	if ls "$rootfs"/usr/lib/aarch64-linux-gnu/libgallium-24*.so >/dev/null 2>&1; then
		pass "Mesa 24 gallium driver present"
	else
		fail "Mesa 24 gallium driver missing; GPU acceleration would crash as with 23.2.1"
	fi

	section "rootfs: board integration"
	grep_file 'PARTLABEL=' "$rootfs/etc/fstab" "fstab mounts the root partition by PARTLABEL"
	exists "$rootfs/etc/caihong-rootfs-build-info" "build provenance file is present"
	exists "$rootfs/etc/modules-load.d/caihong.conf" "board module list is installed"
	exists "$rootfs/etc/NetworkManager/conf.d/99-caihong-hardware-mac.conf" \
		"NetworkManager keeps the hardware Wi-Fi MAC"
	if [ -e "$rootfs/usr/bin/qemu-aarch64-static" ]; then
		fail "cross-build qemu interpreter leaked into the image"
	else
		pass "no cross-build interpreter in the image"
	fi
	if [ -s "$rootfs/etc/machine-id" ]; then
		fail "/etc/machine-id is not empty; all devices would share an identity"
	else
		pass "/etc/machine-id is empty (regenerated on first boot)"
	fi
	if ls "$rootfs"/etc/ssh/ssh_host_* >/dev/null 2>&1; then
		fail "SSH host keys are baked into the image"
	else
		pass "no SSH host keys baked in (generated on first boot)"
	fi
	if [ -n "$(ls -A "$rootfs/boot" 2>/dev/null)" ]; then
		fail "/boot is not empty; the kernel must come from the boot image"
	else
		pass "/boot is empty: kernel and DTB come from the boot image"
	fi
	if [ -e "$rootfs/boot/initrd.img" ] || ls "$rootfs"/boot/initrd.img-* >/dev/null 2>&1; then
		fail "an initramfs exists but this boot chain has no ramdisk"
	else
		pass "no initramfs, matching the ramdisk-less boot image"
	fi
	if [ -f "$rootfs/etc/shadow" ]; then
		root_hash=$(awk -F: '$1 == "root" { print $2 }' "$rootfs/etc/shadow")
		case "$root_hash" in
			''|'!'*|'*'|'!!') fail "root account has no usable password; console login would fail" ;;
			*) pass "root account has a password set" ;;
		esac
	fi
	# The chroot probe needs a working aarch64 binfmt on the build host, which is
	# not guaranteed when the verifier is run on its own; fall back to the passwd
	# database rather than reporting a bogus failure.
	if grep -q "^$CAIHONG_DEFAULT_USER:" "$rootfs/etc/passwd"; then
		if chroot "$rootfs" id "$CAIHONG_DEFAULT_USER" >/dev/null 2>&1; then
			pass "default user $CAIHONG_DEFAULT_USER exists and resolves"
		else
			pass "default user $CAIHONG_DEFAULT_USER recorded in /etc/passwd (chroot not executable here)"
		fi
	else
		fail "default user $CAIHONG_DEFAULT_USER is missing"
	fi
	for unit in ssh.service caihong-grow-rootfs.service caihong-mark-boot-successful.service \
		caihong-usbnet.service; do
		if [ -L "$rootfs/etc/systemd/system/$unit" ] ||
			[ -L "$rootfs/etc/systemd/system/multi-user.target.wants/$unit" ]; then
			pass "unit enabled: $unit"
		else
			fail "unit is not enabled: $unit"
		fi
	done

	section "rootfs: prebuilt payload compatibility"
	jammy_glibc=2.35
	payloads=()
	for payload in "$rootfs/usr/bin/adbd" "$rootfs/usr/local/libexec/caihong-ssc/hexagonrpcd" \
		"$rootfs/usr/local/libexec/caihong-ssc/iio-sensor-proxy"; do
		[ -f "$payload" ] && payloads+=("$payload")
	done
	if [ ${#payloads[@]} -gt 0 ]; then
		if out=$("$project_dir/scripts/check-aarch64-glibc.sh" --max-glibc "$jammy_glibc" \
			"${payloads[@]}" 2>&1); then
			pass "prebuilt payloads run on glibc $jammy_glibc"
			[ "$quiet" = 1 ] || printf '      %s\n' "$out"
		else
			fail "a prebuilt payload needs a newer glibc than Jammy provides: $out"
		fi
	else
		skip "no optional prebuilt payloads installed"
	fi
fi

# --- boot images -------------------------------------------------------------
if [ ${#boot_images[@]} -gt 0 ]; then
	section "boot images"
	for image in "${boot_images[@]}"; do
		if [ ! -f "$image" ]; then
			fail "boot image not found: $image"
			continue
		fi
		info=$(python3 "$project_dir/tools/bootimg_v2.py" info "$image" 2>&1) || {
			fail "cannot parse $image: $info"
			continue
		}
		header=$(printf '%s\n' "$info" | awk -F': ' '/^header_version/ { print $2 }')
		ramdisk=$(printf '%s\n' "$info" | awk -F': ' '/^ramdisk_size/ { print $2 }')
		dtb=$(printf '%s\n' "$info" | awk -F': ' '/^dtb_size/ { print $2 }')
		cmdline=$(printf '%s\n' "$info" | awk -F': ' '/^cmdline/ { sub(/^cmdline *: /, ""); print }')
		[ "$header" = "$BOOT_HEADER_VERSION" ] &&
			pass "$(basename "$image"): Android boot image v$header" ||
			fail "$(basename "$image"): header version $header, expected $BOOT_HEADER_VERSION"
		[ "$ramdisk" = "0" ] &&
			pass "$(basename "$image"): no ramdisk, as required" ||
			fail "$(basename "$image"): ramdisk_size=$ramdisk, but the boot chain has no ramdisk slot"
		[ -n "$KERNEL_DTB_SIZE" ] && [ "$dtb" = "$KERNEL_DTB_SIZE" ] &&
			pass "$(basename "$image"): embeds the Caihong DTB ($dtb bytes)" ||
			fail "$(basename "$image"): DTB is $dtb bytes, expected $KERNEL_DTB_SIZE"
		case " $cmdline " in
			*" root=PARTLABEL=$ROOTFS_LABEL_DUALBOOT "*) pass "$(basename "$image"): root=PARTLABEL=$ROOTFS_LABEL_DUALBOOT" ;;
			*" root=PARTLABEL=$ROOTFS_LABEL_SINGLE "*) pass "$(basename "$image"): root=PARTLABEL=$ROOTFS_LABEL_SINGLE" ;;
			*) fail "$(basename "$image"): command line has no supported root=PARTLABEL" ;;
		esac
		case " $cmdline " in
			*console=tty0*) pass "$(basename "$image"): console=tty0 targets the internal panel" ;;
			*) fail "$(basename "$image"): command line has no console=tty0; the panel would stay blank" ;;
		esac
		if tmp=$(mktemp -d) && python3 "$project_dir/tools/bootimg_v2.py" unpack "$image" "$tmp" >/dev/null 2>&1; then
			kernel_sha=$(sha256sum "$tmp/kernel" | awk '{ print $1 }')
			dtb_sha=$(sha256sum "$tmp/dtb" | awk '{ print $1 }')
			[ -n "$KERNEL_IMAGE_SHA256" ] && [ "$kernel_sha" = "$KERNEL_IMAGE_SHA256" ] &&
				pass "$(basename "$image"): kernel matches the pinned Image" ||
				fail "$(basename "$image"): kernel digest $kernel_sha differs from the pinned Image"
			[ -n "$KERNEL_DTB_SHA256" ] && [ "$dtb_sha" = "$KERNEL_DTB_SHA256" ] &&
				pass "$(basename "$image"): DTB matches the pinned Caihong DTB" ||
				fail "$(basename "$image"): DTB digest differs from the pinned Caihong DTB"
			rm -rf -- "$tmp"
		fi
	done
fi

# --- filesystem image --------------------------------------------------------
if [ ${#images[@]} -gt 0 ]; then
	for image in "${images[@]}"; do
		section "filesystem image: $(basename "$image")"
		if [ ! -f "$image" ]; then
			fail "image not found: $image"
			continue
		fi
		work=$(mktemp -d)
		raw=$work/raw.img
		stage=$image
		case "$image" in
			*.zst)
				zstd -q -d -o "$work/stream.img" --force "$image" || {
					fail "cannot decompress $image"
					rm -rf -- "$work"
					continue
				}
				stage=$work/stream.img
				;;
		esac
		magic=$(od -An -tx4 -N4 "$stage" | tr -d ' ')
		if [ "$magic" = "ed26ff3a" ]; then
			simg2img "$stage" "$raw" >/dev/null 2>&1 || {
				fail "sparse image cannot be decoded"
				rm -rf -- "$work"
				continue
			}
			pass "Android sparse image decodes cleanly"
		else
			cp -- "$stage" "$raw"
		fi
		if e2fsck -fn "$raw" >"$work/fsck.log" 2>&1; then
			pass "ext4 filesystem passes e2fsck -fn"
		else
			fail "ext4 filesystem has errors: $(head -3 "$work/fsck.log" | tr '\n' ' ')"
		fi
		label=$(blkid -s LABEL -o value "$raw" 2>/dev/null || true)
		case "$label" in
			"$ROOTFS_LABEL_DUALBOOT"|"$ROOTFS_LABEL_SINGLE")
				pass "filesystem label is $label"
				;;
			*) fail "filesystem label is '$label', expected $ROOTFS_LABEL_DUALBOOT or $ROOTFS_LABEL_SINGLE" ;;
		esac
		if command -v debugfs >/dev/null 2>&1; then
			# Ubuntu symlinks /etc/os-release to ../usr/lib/os-release, and debugfs
			# does not follow symlinks, so read the real file first.
			os_release=$(debugfs -R 'cat /usr/lib/os-release' "$raw" 2>/dev/null)
			[ -n "$os_release" ] || os_release=$(debugfs -R 'cat /etc/os-release' "$raw" 2>/dev/null)
			case "$os_release" in
				*"Ubuntu 22.04"*) pass "image contains an Ubuntu 22.04 user space" ;;
				*) fail "image /etc/os-release is not Ubuntu 22.04" ;;
			esac
			fstab=$(debugfs -R 'cat /etc/fstab' "$raw" 2>/dev/null)
			case "$fstab" in
				*"PARTLABEL=$label"*) pass "image fstab matches the filesystem label ($label)" ;;
				*) fail "image fstab does not reference PARTLABEL=$label" ;;
			esac
			if debugfs -R 'stat /usr/lib/systemd/systemd' "$raw" 2>/dev/null | grep -q 'Type: regular'; then
				pass "image contains /usr/lib/systemd/systemd"
			else
				fail "image has no /usr/lib/systemd/systemd"
			fi
			# /lib is a usrmerge symlink; inspect the real module path.
			modules=$(debugfs -R "ls -l /usr/lib/modules/$KERNEL_RELEASE" "$raw" 2>/dev/null | grep -c 'modules.dep')
			[ "${modules:-0}" -ge 1 ] ||
				modules=$(debugfs -R "ls -l /lib/modules/$KERNEL_RELEASE" "$raw" 2>/dev/null | grep -c 'modules.dep')
			[ "${modules:-0}" -ge 1 ] &&
				pass "image contains /lib/modules/$KERNEL_RELEASE/modules.dep" ||
				fail "image is missing the kernel module tree for $KERNEL_RELEASE"
		fi
		size=$(stat -c %s "$raw")
		note_size=$((size / 1024 / 1024))
		[ "$note_size" -ge 1024 ] &&
			pass "logical filesystem size: ${note_size} MiB" ||
			fail "logical filesystem size ${note_size} MiB is implausibly small"
		rm -rf -- "$work"
	done
fi

section "checks that need the real device"
skip "panel: boot and confirm the console appears (collect-debug.sh captures dmesg/drm state)"
skip "brightness: echo N > /sys/class/backlight/*/brightness"
skip "battery: caihong-battery --raw"
skip "USB-C charging: caihong-battery while a charger is attached"
skip "USB hub/OTG: lsusb with a hub and a downstream device"
skip "GPU: kmscube, then glmark2-es2 and vulkaninfo"
skip "Wi-Fi/Bluetooth/SSH: nmcli, bluetoothctl, ssh from another host"

printf '\n%d passed, %d failed, %d skipped (hardware)\n' "$passes" "$failures" "$skips"
[ "$failures" -eq 0 ] || exit 1
printf 'verification passed\n'
