#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
#
# Collect the Caihong hardware state and kernel logs into one archive.
#
# Run this on the device *after* booting Ubuntu, and again after plugging in a
# charger, a USB-C hub or an external display, so the two archives can be
# compared. It is read-only: it never writes outside the output directory.
#
# usage: sudo scripts/collect-debug.sh [--out DIR] [--quick]
set -Eeuo pipefail
CDPATH=

out_dir=/tmp
quick=0
while [ $# -gt 0 ]; do
	case $1 in
		--out) out_dir=${2:?--out needs a directory}; shift 2 ;;
		--quick) quick=1; shift ;;
		-h|--help)
			sed -n '2,12p' "$0"
			exit 0
			;;
		*) echo "unknown option: $1" >&2; exit 2 ;;
	esac
done

[ "$(id -u)" -eq 0 ] || { echo "run as root: dmesg and device state need privileges" >&2; exit 1; }

stamp=$(date +%Y%m%d-%H%M%S)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT HUP INT TERM
dest="$work/caihong-debug-$stamp"
mkdir -p "$dest"

# Run a command and store its output, never failing the whole collection when a
# single subsystem is missing or broken (that absence is itself the finding).
capture()
{
	local name=$1
	shift
	{
		printf '$ %s\n' "$*"
		"$@" 2>&1 || printf '\n[exit code %d]\n' "$?"
	} > "$dest/$name.txt"
}

capture_version()
{
	local name=$1
	shift
	{
		printf '$ %s\n' "$*"
		"$@" 2>&1 || printf '\n[exit status: command unavailable or failed]\n'
	} > "$dest/$name.txt"
}

echo "collecting system identity"
capture uname uname -a
capture os-release cat /etc/os-release
capture build-info cat /etc/caihong-rootfs-build-info
capture cmdline cat /proc/cmdline
capture version cat /proc/version
capture date date -u
capture uptime cat /proc/uptime
capture modules lsmod
capture systemd-failed systemctl --failed --no-pager
capture systemd-units systemctl --no-pager --type=service --state=running
capture kernel-messages dmesg --time-format=iso
capture journal-boot journalctl -b --no-pager -o short-monotonic

if [ -r /proc/config.gz ]; then
	zcat /proc/config.gz > "$dest/kernel-config.txt"
else
	echo "kernel has no /proc/config.gz (CONFIG_IKCONFIG_PROC)" > "$dest/kernel-config.txt"
fi

echo "collecting display state"
capture drm-devices ls -l /dev/dri
capture drm-status sh -c 'for f in /sys/class/drm/*/status; do printf "%s: %s\n" "$f" "$(cat "$f")"; done'
capture drm-modes sh -c 'for f in /sys/class/drm/card*/card*/modes; do [ -f "$f" ] || continue; printf "%s\n" "$f"; sed "s/^/  /" "$f"; done'
capture drm-edid sh -c 'for f in /sys/class/drm/card*/card*/edid; do [ -s "$f" ] || continue; printf "%s: %s bytes\n" "$f" "$(stat -c %s "$f")"; done'
capture backlight sh -c 'for d in /sys/class/backlight/*; do [ -d "$d" ] || continue; printf "%s max=%s brightness=%s actual=%s\n" "$d" "$(cat "$d/max_brightness" 2>/dev/null)" "$(cat "$d/brightness" 2>/dev/null)" "$(cat "$d/actual_brightness" 2>/dev/null)"; done'
capture fbcon cat /sys/class/vtconsole/vtcon1/name 2>/dev/null || true
capture msm-debugfs sh -c 'ls /sys/kernel/debug/dri/*/ 2>/dev/null | head -50'

echo "collecting power state"
if command -v caihong-battery >/dev/null 2>&1; then
	capture battery caihong-battery
	capture battery-raw caihong-battery --raw
else
	echo "caihong-battery is not installed" > "$dest/battery.txt"
fi
capture power-supply sh -c 'for d in /sys/class/power_supply/*; do [ -d "$d" ] || continue; printf "== %s\n" "${d##*/}"; for a in type online status present capacity health voltage_now current_now current_max voltage_max temp charge_type charge_control_limit; do [ -r "$d/$a" ] && printf "  %-22s %s\n" "$a" "$(cat "$d/$a")"; done; done'
capture thermal sh -c 'for z in /sys/class/thermal/thermal_zone*; do [ -d "$z" ] || continue; printf "%s %-24s %s\n" "$z" "$(cat "$z/type" 2>/dev/null)" "$(cat "$z/temp" 2>/dev/null)"; done'
capture cooling-devices sh -c 'for c in /sys/class/thermal/cooling_device*; do printf "%s %s %s\n" "$c" "$(cat "$c/type" 2>/dev/null)" "$(cat "$c/cur_state" 2>/dev/null)"; done'
capture cpufreq sh -c 'for c in /sys/devices/system/cpu/cpu*/cpufreq; do [ -d "$c" ] || continue; printf "%s: %s governor, %s..%s kHz, now %s\n" "${c%/cpufreq}" "$(cat "$c/scaling_governor" 2>/dev/null)" "$(cat "$c/scaling_min_freq" 2>/dev/null)" "$(cat "$c/scaling_max_freq" 2>/dev/null)" "$(cat "$c/scaling_cur_freq" 2>/dev/null)"; done'
capture suspend sh -c 'cat /sys/power/state; cat /sys/power/mem_sleep 2>/dev/null'

echo "collecting USB and Type-C state"
capture usb-devices lsusb
capture usb-tree lsusb -t
capture usb-roles sh -c 'for r in /sys/class/usb_role/*; do [ -d "$r" ] || continue; printf "%s: role=%s\n" "$r" "$(cat "$r/role" 2>/dev/null)"; done'
capture typec sh -c 'for p in /sys/class/typec/port*; do [ -d "$p" ] || continue; printf "== %s\n" "${p##*/}"; for a in data_role power_role power_operation_mode; do [ -r "$p/$a" ] && printf "  %-24s %s\n" "$a" "$(cat "$p/$a")"; done; ls "$p" | sed "s/^/  /"; done'
capture udc sh -c 'for u in /sys/class/udc/*; do [ -d "$u" ] || continue; printf "%s: state=%s\n" "${u##*/}" "$(cat "$u/state" 2>/dev/null)"; done'
capture dwc3 sh -c 'ls /sys/bus/platform/drivers/dwc3/ 2>/dev/null'

echo "collecting network and sensors"
capture network nmcli device 2>/dev/null || true
capture network-detail nmcli device show 2>/dev/null || true
capture rfkill rfkill list
capture iio sh -c 'for d in /sys/bus/iio/devices/*; do [ -d "$d" ] || continue; printf "== %s\n" "${d##*/}"; cat "$d/name" 2>/dev/null; done'
capture input sh -c 'grep -H . /sys/class/input/*/name 2>/dev/null'
capture bluetooth sh -c 'bluetoothctl list 2>/dev/null; bluetoothctl show 2>/dev/null'

echo "collecting storage and memory"
capture block lsblk -o NAME,SIZE,FSTYPE,LABEL,PARTLABEL,MOUNTPOINTS
capture partitions cat /proc/partitions
capture mounts findmnt --noheadings --output TARGET,SOURCE,FSTYPE,OPTIONS
capture filesystems df -h
capture memory free -m
capture zram sh -c 'cat /proc/swaps; for z in /sys/block/zram*; do [ -d "$z" ] || continue; printf "%s disksize=%s\n" "$z" "$(cat "$z/disksize" 2>/dev/null)"; done'
capture ufs sh -c 'for h in /sys/class/scsi_host/host*; do [ -d "$h" ] || continue; printf "%s %s\n" "$h" "$(cat "$h/proc_name" 2>/dev/null)"; done'
capture remoteproc sh -c 'for r in /sys/class/remoteproc/remoteproc*; do [ -d "$r" ] || continue; printf "%s: %s state=%s\n" "$r" "$(cat "$r/name" 2>/dev/null)" "$(cat "$r/state" 2>/dev/null)"; done'
capture socinfo sh -c 'cat /sys/devices/soc0/* 2>/dev/null | head -40'

if [ "$quick" = 0 ]; then
	echo "collecting GPU runtime information (may take a few seconds)"
	capture gpu-vulkan vulkaninfo --summary 2>/dev/null || true
	capture gpu-egl eglinfo 2>/dev/null || true
	capture gpu-glx glxinfo -B 2>/dev/null || true
	capture gpu-kmscube sh -c 'timeout 20 kmscube -c 60 2>&1 | tail -20'
	capture gpu-freq sh -c 'for g in /sys/class/devfreq/*gpu*; do [ -d "$g" ] || continue; printf "%s: cur=%s\n" "$g" "$(cat "$g/cur_freq" 2>/dev/null)"; done'
else
	echo "skipping GPU runtime tests (--quick)"
fi

echo "collecting firmware load results"
capture firmware-loads sh -c 'dmesg | grep -iE "firmware|remoteproc|qcom_|msm_|ath12k|adsprpc|fastrpc" | tail -200'
capture failures sh -c 'dmesg --level=err,warn | tail -200'

{
	echo "caihong debug archive"
	echo "collector: collect-debug.sh"
	echo "created:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
	echo "host:      $(uname -n)"
	echo "kernel:    $(uname -r)"
	echo "quick:     $quick"
} > "$dest/README.txt"

tar -czf "$out_dir/caihong-debug-$stamp.tar.gz" -C "$work" "caihong-debug-$stamp"

echo
echo "archive: $out_dir/caihong-debug-$stamp.tar.gz ($(stat -c %s "$out_dir/caihong-debug-$stamp.tar.gz") bytes)"
echo
echo "quick look:"
printf '  kernel      : %s\n' "$(uname -r)"
printf '  DRM cards   : %s\n' "$(ls /dev/dri 2>/dev/null | tr '\n' ' ')"
if [ -r /sys/class/drm/card0-HDMI-A-1/status ]; then
	printf '  DP/HDMI     : %s\n' "$(cat /sys/class/drm/card0-HDMI-A-1/status)"
fi
printf '  backlight   : %s\n' "$(ls /sys/class/backlight 2>/dev/null | tr '\n' ' ')"
printf '  power supply: %s\n' "$(ls /sys/class/power_supply 2>/dev/null | tr '\n' ' ')"
printf '  failed units: %s\n' "$(systemctl --failed --no-legend --no-pager 2>/dev/null | wc -l)"
