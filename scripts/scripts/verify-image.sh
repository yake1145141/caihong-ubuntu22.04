#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
#
# Compatibility entry point: the task specification names this check
# "verify-image.sh", while the implementation lives in verify-ubuntu-image.sh
# (which also verifies the rootfs tree and boot images, not just the image).
#
# usage: scripts/verify-image.sh [--rootfs DIR] [--boot IMG] [--image IMG]
set -Eeuo pipefail
project_dir=$(cd -- "$(dirname -- "$0")/.." && pwd)
exec "$project_dir/scripts/verify-ubuntu-image.sh" "$@"
