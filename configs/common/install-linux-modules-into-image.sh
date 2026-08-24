#!/usr/bin/env bash
# Overlay staged Linux modules (*.ko) and PowerVR firmware onto an existing
# ext2/ext4 rootfs image.
# Usage: install-linux-modules-into-image.sh <IMAGE>
#
# Used for ubuntu / debian / yocto (they emit a packed ext4). OpenWrt injects
# both into the unpacked stage instead (see scripts/recipes.sh).
set -euo pipefail

IMAGE="${1:?usage: $0 <IMAGE>}"
SCRIPT_DIR="$(cd "$(dirname -- "$0")" && pwd)"
BUILD_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
STAGING="${OPENTINA_LINUX_MODULES_STAGING:-$BUILD_ROOT/.staging-linux-modules}"
INSTALL_TREE="$SCRIPT_DIR/install-linux-modules.sh"
INSTALL_FW="$SCRIPT_DIR/install-powervr-firmware.sh"
FW_CACHE="${OPENTINA_FIRMWARE_CACHE:-$BUILD_ROOT/dl/firmware/powervr}"
OUT_DIR="$(cd "$(dirname -- "$IMAGE")" && pwd)"
MNT="$OUT_DIR/.modules-overlay-mnt"
STAGE="$OUT_DIR/.rootfs-modules-stage"

if [ ! -f "$IMAGE" ]; then
	echo "install-linux-modules-into-image: missing $IMAGE" >&2
	exit 1
fi

# Seed firmware cache on the host before any docker/fakeroot overlay.
"$INSTALL_FW" --fetch || exit 1

overlay_tree() {
	local dest="$1"
	"$INSTALL_TREE" "$dest" || return 1
	"$INSTALL_FW" "$dest" || return 1
	return 0
}

overlay_loop() {
	mkdir -p "$MNT" || return 1
	mount -o loop "$IMAGE" "$MNT" || return 1
	if ! overlay_tree "$MNT"; then
		umount "$MNT" || true
		return 1
	fi
	umount "$MNT" || return 1
	rmdir "$MNT" 2>/dev/null || true
	return 0
}

overlay_loop_sudo() {
	mkdir -p "$MNT" || return 1
	sudo mount -o loop "$IMAGE" "$MNT" || return 1
	if ! sudo env OPENTINA_LINUX_MODULES_STAGING="$STAGING" \
		OPENTINA_FIRMWARE_CACHE="$FW_CACHE" \
		"$INSTALL_TREE" "$MNT"; then
		sudo umount "$MNT" || true
		return 1
	fi
	if ! sudo env OPENTINA_FIRMWARE_CACHE="$FW_CACHE" "$INSTALL_FW" "$MNT"; then
		sudo umount "$MNT" || true
		return 1
	fi
	sudo umount "$MNT" || return 1
	rmdir "$MNT" 2>/dev/null || true
	return 0
}

# Non-root path: unpack with debugfs, copy modules + firmware, remake the image
# in one fakeroot session so uid/gid (including device nodes) survive into mkfs.
repack_fakeroot() {
	command -v debugfs >/dev/null 2>&1 || return 1
	command -v mkfs.ext4 >/dev/null 2>&1 || return 1
	command -v fakeroot >/dev/null 2>&1 || return 1

	local uuid="" label=""
	if command -v tune2fs >/dev/null 2>&1; then
		uuid="$(tune2fs -l "$IMAGE" 2>/dev/null | awk '/Filesystem UUID:/ {print $3}')" || true
		label="$(tune2fs -l "$IMAGE" 2>/dev/null | sed -n 's/^Filesystem volume name:[[:space:]]*//p')" || true
	fi
	[ "$label" = "<none>" ] && label=""

	rm -rf "$STAGE"
	mkdir -p "$STAGE" || return 1

	# $1=image $2=stage $3=install-modules $4=staging $5=label $6=uuid $7=install-fw
	fakeroot -- sh -c '
		set -e
		image="$1"
		stage="$2"
		install="$3"
		export OPENTINA_LINUX_MODULES_STAGING="$4"
		label="$5"
		uuid="$6"
		install_fw="$7"
		debugfs -R "rdump / $stage" "$image" >/dev/null
		rm -rf "$stage/lost+found"
		"$install" "$stage"
		"$install_fw" "$stage"
		set -- -t ext4 -d "$stage" -m 0 -F
		[ -n "$label" ] && set -- "$@" -L "$label"
		[ -n "$uuid" ] && set -- "$@" -U "$uuid"
		mkfs.ext4 "$@" "$image" >/dev/null
	' -- "$IMAGE" "$STAGE" "$INSTALL_TREE" "$STAGING" "$label" "${uuid:-}" "$INSTALL_FW" || {
		rm -rf "$STAGE"
		return 1
	}

	rm -rf "$STAGE"
	return 0
}

overlay_docker() {
	command -v docker >/dev/null 2>&1 || return 1
	[ -z "${OPENTINA_IN_DOCKER:-}" ] || return 1

	local dimg="${OPENTINA_MKE2FS_IMAGE:-opentina-buildenv:24.04}"
	local dockerfile="$BUILD_ROOT/docker/Dockerfile"
	docker image inspect "$dimg" >/dev/null 2>&1 \
		|| docker build -t "$dimg" -f "$dockerfile" "$BUILD_ROOT/docker" \
		|| return 1

	local staging_vol=()
	[ -d "$STAGING" ] && staging_vol=(-v "$STAGING:/staging:ro")

	docker run --rm --privileged \
		-e OPENTINA_LINUX_MODULES_STAGING=/staging \
		-e OPENTINA_FIRMWARE_CACHE=/fwcache \
		-v "$IMAGE:/image.ext4" \
		"${staging_vol[@]}" \
		-v "$INSTALL_TREE:/install-linux-modules.sh:ro" \
		-v "$INSTALL_FW:/install-powervr-firmware.sh:ro" \
		-v "$FW_CACHE:/fwcache:ro" \
		--user 0:0 "$dimg" \
		sh -c 'mkdir -p /mnt && mount -o loop /image.ext4 /mnt && /install-linux-modules.sh /mnt && /install-powervr-firmware.sh /mnt && umount /mnt' \
		|| return 1
	return 0
}

echo "install-linux-modules-into-image: overlay modules + PowerVR firmware -> $IMAGE"

if [ "$(id -u)" -eq 0 ] && overlay_loop; then
	exit 0
fi

if [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null \
	&& overlay_loop_sudo; then
	exit 0
fi

if repack_fakeroot; then
	exit 0
fi

if overlay_docker; then
	exit 0
fi

echo "install-linux-modules-into-image: need root, passwordless sudo, fakeroot+debugfs+mkfs.ext4, or docker to copy *.ko/firmware into $IMAGE" >&2
exit 1
