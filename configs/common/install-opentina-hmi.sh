#!/usr/bin/env bash
# Install the OpenTina HMI validation scripts into a rootfs-like tree.
# Usage: install-opentina-hmi.sh <DEST_ROOT>
#
# No-op unless OPENTINA_HMI=1, so the console profiles stay unchanged.
set -euo pipefail

DEST_ROOT="${1:?usage: $0 <DEST_ROOT>}"
SCRIPT_DIR="$(cd "$(dirname -- "$0")" && pwd)"
SRC="${OPENTINA_HMI_FILES:-$SCRIPT_DIR/opentina-hmi}"

if [ "${OPENTINA_HMI:-0}" != "1" ]; then
	exit 0
fi
[ -d "$SRC" ] || { echo "install-opentina-hmi: missing $SRC" >&2; exit 1; }

install -D -m 0755 "$SRC/opentina-hmi-check" "$DEST_ROOT/usr/bin/opentina-hmi-check"
install -D -m 0755 "$SRC/gst-scenarios.sh" \
	"$DEST_ROOT/usr/share/opentina/demo/gst-scenarios.sh"
install -D -m 0644 "$SRC/weston.ini" "$DEST_ROOT/etc/xdg/weston/weston.ini"

# systemd images get opentina-weston.service from their own overlay; only the
# busybox/SysV images need this init script.
if [ ! -d "$DEST_ROOT/usr/lib/systemd/system" ] && [ ! -d "$DEST_ROOT/lib/systemd/system" ]; then
	install -D -m 0755 "$SRC/S40weston" "$DEST_ROOT/etc/init.d/S40weston"
	echo "install-opentina-hmi: installed the SysV weston init script"
fi
echo "install-opentina-hmi: installed HMI validation scripts -> $DEST_ROOT"
