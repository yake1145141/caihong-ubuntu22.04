#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
#
# Verify that prebuilt aarch64 binaries can actually run on the Ubuntu Jammy
# user space we are assembling.
#
# The reference project ships a few prebuilt payloads (the SSC sensor stack, for
# example) that were produced on Arch Linux. Jammy provides glibc 2.35, so any
# binary that requests GLIBC_2.36 or newer fails at load time with
# "version `GLIBC_2.xx' not found" -- a failure that is easy to miss when the
# payload is merely copied into an image.
#
# usage: check-aarch64-glibc.sh [--max-glibc VERSION] FILE...
#
# exit status 0: every binary fits; 1: at least one needs a newer glibc, or a
# file is not an aarch64 ELF object.
set -Eeuo pipefail
CDPATH=

max_glibc=2.35
files=()

while [ $# -gt 0 ]; do
	case $1 in
		--max-glibc)
			[ $# -ge 2 ] || { echo "error: --max-glibc needs a value" >&2; exit 2; }
			max_glibc=$2
			shift 2
			;;
		--max-glibc=*)
			max_glibc=${1#*=}
			shift
			;;
		--)
			shift
			while [ $# -gt 0 ]; do files+=("$1"); shift; done
			;;
		-*)
			echo "error: unknown option $1" >&2
			exit 2
			;;
		*)
			files+=("$1")
			shift
			;;
	esac
done

[ ${#files[@]} -gt 0 ] || { echo "usage: $0 [--max-glibc VERSION] FILE..." >&2; exit 2; }
command -v readelf >/dev/null 2>&1 || { echo "error: readelf is unavailable" >&2; exit 1; }

# version_gt A B -> true when A is newer than B
version_gt()
{
	[ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n 1)" = "$1" ]
}

failures=0
worst=0.0
worst_file=

for file in "${files[@]}"; do
	if [ ! -f "$file" ]; then
		echo "missing file: $file" >&2
		failures=$((failures + 1))
		continue
	fi
	machine=$(readelf -h "$file" 2>/dev/null | awk -F: '/^ *Machine:/ { gsub(/^ +| +$/, "", $2); print $2 }')
	if [ "$machine" != "AArch64" ]; then
		echo "$(basename "$file"): not an AArch64 ELF object (machine: ${machine:-unknown})" >&2
		failures=$((failures + 1))
		continue
	fi

	# grep returns 1 when a binary has no GLIBC_xx symbols at all (a fully static
	# binary); under `set -o pipefail` that would abort the whole check.
	needed=$( { readelf --version-info "$file" 2>/dev/null |
		grep -oE 'GLIBC_[0-9]+(\.[0-9]+)+' | sed 's/^GLIBC_//' | sort -Vu | tail -n 1; } || true)
	cxx=$( { readelf --version-info "$file" 2>/dev/null |
		grep -oE 'GLIBCXX_[0-9]+(\.[0-9]+)+' | sed 's/^GLIBCXX_//' | sort -Vu | tail -n 1; } || true)
	needed=${needed:-none}

	if [ "$needed" = none ]; then
		echo "$(basename "$file"): static, no glibc requirement"
		continue
	fi

	if version_gt "$needed" "$max_glibc"; then
		printf '%s: requires GLIBC_%s, target provides %s\n' \
			"$(basename "$file")" "$needed" "$max_glibc" >&2
		failures=$((failures + 1))
	else
		printf '%s: requires GLIBC_%s (<= %s)\n' "$(basename "$file")" "$needed" "$max_glibc"
	fi
	if [ "$cxx" != "" ] && version_gt "$cxx" "$max_glibc"; then
		printf 'warning: %s also needs GLIBCXX_%s; verify libstdc++ availability\n' \
			"$(basename "$file")" "$cxx" >&2
	fi
	if version_gt "$needed" "$worst"; then
		worst=$needed
		worst_file=$(basename "$file")
	fi
done

if [ "$failures" -ne 0 ]; then
	printf 'FAILED: %d of %d payload(s) cannot run on this user space\n' \
		"$failures" "${#files[@]}" >&2
	exit 1
fi
printf 'OK: highest requirement GLIBC_%s (%s), target glibc %s\n' \
	"$worst" "${worst_file:-none}" "$max_glibc"
