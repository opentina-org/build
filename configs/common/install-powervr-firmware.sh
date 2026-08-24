#!/usr/bin/env bash
# Fetch Imagination PowerVR firmware (if missing) and optionally install into a rootfs.
# Usage:
#   install-powervr-firmware.sh --fetch          # download to dl/firmware only
#   install-powervr-firmware.sh <DEST_ROOT>      # fetch if needed, then install
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname -- "$0")" && pwd)"
BUILD_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

FW_NAME="rogue_36.56.104.183_v1.fw"
FW_RELDIR="powervr"
FW_URL="https://gitlab.freedesktop.org/imagination/linux-firmware/-/raw/powervr/powervr/${FW_NAME}?inline=false"
CACHE_DIR="${OPENTINA_FIRMWARE_CACHE:-$BUILD_ROOT/dl/firmware/$FW_RELDIR}"
CACHE_FILE="$CACHE_DIR/$FW_NAME"

fetch_only=0
DEST_ROOT=""
if [ "${1:-}" = "--fetch" ]; then
	fetch_only=1
elif [ -n "${1:-}" ]; then
	DEST_ROOT="$1"
else
	echo "usage: $0 --fetch | <DEST_ROOT>" >&2
	exit 1
fi

download_fw() {
	local tmp
	mkdir -p "$CACHE_DIR"
	tmp="$(mktemp "$CACHE_DIR/${FW_NAME}.XXXXXX")"
	echo "Downloading PowerVR firmware: $FW_URL"
	if command -v curl >/dev/null 2>&1; then
		curl -fL --retry 3 --retry-delay 2 -o "$tmp" "$FW_URL"
	elif command -v wget >/dev/null 2>&1; then
		wget -O "$tmp" "$FW_URL"
	else
		rm -f "$tmp"
		echo "install-powervr-firmware: need curl or wget to fetch $FW_NAME" >&2
		exit 1
	fi
	if [ ! -s "$tmp" ]; then
		rm -f "$tmp"
		echo "install-powervr-firmware: downloaded file is empty" >&2
		exit 1
	fi
	mv -f "$tmp" "$CACHE_FILE"
}

mkdir -p "$CACHE_DIR"
if [ ! -s "$CACHE_FILE" ]; then
	download_fw
else
	echo "Using cached PowerVR firmware: $CACHE_FILE"
fi

if [ "$fetch_only" -eq 1 ]; then
	exit 0
fi

# Follow merged-usr (/lib -> usr/lib) when present; otherwise create /lib/firmware.
DEST_DIR="$DEST_ROOT/lib/firmware/$FW_RELDIR"
DEST_FILE="$DEST_DIR/$FW_NAME"
mkdir -p "$DEST_DIR"
cp -f "$CACHE_FILE" "$DEST_FILE"
chmod 644 "$DEST_FILE"
if [ "$(id -u)" -eq 0 ]; then
	chown 0:0 "$DEST_FILE"
fi
echo "Installed $DEST_FILE ($(wc -c < "$DEST_FILE") bytes)"
