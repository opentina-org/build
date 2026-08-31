#!/usr/bin/env bash
# Buildroot BR2_ROOTFS_POST_BUILD_SCRIPT — install all Linux .ko modules into rootfs.
# $1 = TARGET_DIR
set -euo pipefail

TARGET_DIR="${1:?TARGET_DIR missing}"
SCRIPT_DIR="$(cd "$(dirname -- "$0")" && pwd)"
"$SCRIPT_DIR/install-linux-modules.sh" "$TARGET_DIR"
"$SCRIPT_DIR/install-powervr-firmware.sh" "$TARGET_DIR"

# Allow root password login over SSH (only account is root, see
# BR2_TARGET_GENERIC_ROOT_PASSWD; upstream default is prohibit-password).
if [ -f "$TARGET_DIR/etc/ssh/sshd_config" ]; then
	sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' \
		"$TARGET_DIR/etc/ssh/sshd_config"
fi
