#!/usr/bin/env bash
# Buildroot BR2_ROOTFS_POST_BUILD_SCRIPT — install all Linux .ko modules into rootfs.
# $1 = TARGET_DIR
set -euo pipefail

TARGET_DIR="${1:?TARGET_DIR missing}"
SCRIPT_DIR="$(cd "$(dirname -- "$0")" && pwd)"
"$SCRIPT_DIR/install-linux-modules.sh" "$TARGET_DIR"
"$SCRIPT_DIR/install-powervr-firmware.sh" "$TARGET_DIR"
