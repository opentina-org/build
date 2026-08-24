#!/usr/bin/env bash
# Copy staged Linux modules into a rootfs-like tree.
# Usage: install-linux-modules.sh <DEST_ROOT>
# Expects modules previously installed under:
#   $OPENTINA_BUILD_ROOT/.staging-linux-modules/lib/modules/<kernelrelease>/
set -euo pipefail

DEST_ROOT="${1:?usage: $0 <DEST_ROOT>}"
SCRIPT_DIR="$(cd "$(dirname -- "$0")" && pwd)"
BUILD_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
STAGING="${OPENTINA_LINUX_MODULES_STAGING:-$BUILD_ROOT/.staging-linux-modules}"

if [ ! -d "$STAGING/lib/modules" ]; then
	echo "install-linux-modules: no staging tree at $STAGING/lib/modules (build linux first)"
	exit 0
fi

mkdir -p "$DEST_ROOT/lib/modules"
# Replace previous kernel module trees so stale releases do not accumulate.
find "$DEST_ROOT/lib/modules" -mindepth 1 -maxdepth 1 -type d -exec rm -rf {} +
cp -a "$STAGING/lib/modules/." "$DEST_ROOT/lib/modules/"
# Fakeroot (id 0) records root ownership into the packed image.
if [ "$(id -u)" -eq 0 ]; then
	chown -R 0:0 "$DEST_ROOT/lib/modules"
fi

count="$(find "$DEST_ROOT/lib/modules" -type f -name '*.ko*' | wc -l)"
echo "install-linux-modules: installed $count module file(s) under $DEST_ROOT/lib/modules"
