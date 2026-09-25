#!/usr/bin/env bash
# Buildroot BR2_ROOTFS_POST_BUILD_SCRIPT — install all Linux .ko modules into rootfs.
# $1 = TARGET_DIR
set -euo pipefail

TARGET_DIR="${1:?TARGET_DIR missing}"
SCRIPT_DIR="$(cd "$(dirname -- "$0")" && pwd)"
"$SCRIPT_DIR/install-linux-modules.sh" "$TARGET_DIR"
"$SCRIPT_DIR/install-powervr-firmware.sh" "$TARGET_DIR"
if [ "${OPENTINA_OPTEE:-1}" != "0" ]; then
	bash "$SCRIPT_DIR/install-optee-ta.sh" "$TARGET_DIR"
fi
# No-op unless OPENTINA_HMI=1 (set by the br2 hmi profile).
bash "$SCRIPT_DIR/install-opentina-hmi.sh" "$TARGET_DIR"
