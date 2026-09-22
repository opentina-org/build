#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Component-only CI (no sdcard.img). Used by firmware-component.yml.
# Coverage follows the build-repo PR subset: demo × rootfs/optee, demo
# buildroot/no-optee, a7a buildroot/optee — plus linux OpenWrt fragments.
#
# Environment:
#   OPENTINA_BUILD_ROOT  Checkout of the build repo
#   FIRMWARE_SRC         Checkout of the PR (default: $PWD)
#   FIRMWARE_PROJECT     linux | u-boot | optee_os | trusted-firmware-a |
#                        awbin | buildroot | ubuntu | debian | openwrt |
#                        meta-opentina
#   OPENTINA_GH_TOKEN    Optional PAT for private opentina-org clones

set -euo pipefail

script_dir="$(dirname -- "$(realpath -- "$0")")"
OPENTINA_BUILD_ROOT="${OPENTINA_BUILD_ROOT:-$(dirname -- "$script_dir")}"
export OPENTINA_BUILD_ROOT
FIRMWARE_SRC="$(realpath -- "${FIRMWARE_SRC:-$PWD}")"
sdkRoot="$OPENTINA_BUILD_ROOT/sources"
export sdkRoot
mkdir -p "$sdkRoot"

project="${1:-${FIRMWARE_PROJECT:-}}"
case "$project" in
linux) project=linux ;;
u-boot | uboot) project=u-boot ;;
optee_os | optee) project=optee_os ;;
trusted-firmware-a | atf | tf-a) project=trusted-firmware-a ;;
awbin) project=awbin ;;
buildroot | br2) project=buildroot ;;
ubuntu) project=ubuntu ;;
debian) project=debian ;;
openwrt) project=openwrt ;;
meta-opentina | yocto) project=meta-opentina ;;
*)
	echo "ci-firmware-build: unsupported project ${project:-<empty>}" >&2
	exit 1
	;;
esac

if [ -n "${OPENTINA_GH_TOKEN:-}" ]; then
	git config --global url."https://x-access-token:${OPENTINA_GH_TOKEN}@github.com/".insteadOf "https://github.com/"
fi

link_self() {
	local dest="$sdkRoot/$1"
	mkdir -p "$(dirname -- "$dest")"
	rm -rf "$dest"
	ln -sfn "$FIRMWARE_SRC" "$dest"
	echo "tree $1 -> $FIRMWARE_SRC"
}

clone_dep() {
	local name="$1"
	local dest="$sdkRoot/$name"
	if [ -e "$dest/.git" ] || [ -L "$dest" ]; then
		echo "dep exists: $name"
		return 0
	fi
	echo "clone $name (tina-dev, depth=1)"
	git clone --depth 1 --branch tina-dev \
		"https://github.com/opentina-org/${name}.git" "$dest"
}

run_build() {
	echo "========== $* =========="
	"$OPENTINA_BUILD_ROOT/build.sh" "$@"
}

# Same kconfig, both boards (a7a mainly differs by DTB).
linux_boards() {
	local tee_flag="$1"
	local rootfs="$2"
	run_build "$tee_flag" demo_aiot_a733_v3 "$rootfs" build linux
	run_build "$tee_flag" radxa_a7a "$rootfs" build linux
}

rootfs_boards() {
	local tee_flag="$1"
	local rootfs="$2"
	local component="$3"
	run_build "$tee_flag" demo_aiot_a733_v3 "$rootfs" build "$component"
	run_build "$tee_flag" radxa_a7a "$rootfs" build "$component"
}

# Packs SPL FIT with awbin header + bootpackage.py (needs ATF, optional OP-TEE).
build_uboot_pr() {
	run_build --optee demo_aiot_a733_v3 buildroot build optee atf uboot
	run_build --optee radxa_a7a buildroot build optee atf uboot
	run_build --no-optee demo_aiot_a733_v3 buildroot build atf uboot
}

link_self "$project"

case "$project" in
linux)
	# Unique kernel fragments, each followed by a7a (same Image, other DTB).
	linux_boards --optee buildroot
	linux_boards --no-optee buildroot
	linux_boards --optee ubuntu
	linux_boards --optee openwrt
	;;
trusted-firmware-a)
	run_build --optee demo_aiot_a733_v3 buildroot build atf
	run_build --no-optee demo_aiot_a733_v3 buildroot build atf
	;;
optee_os)
	run_build --optee demo_aiot_a733_v3 buildroot build optee
	;;
u-boot)
	clone_dep trusted-firmware-a
	clone_dep optee_os
	clone_dep awbin
	build_uboot_pr
	;;
awbin)
	for board in demo_aiot_a733_v3 radxa_a7a; do
		boot0="$sdkRoot/awbin/bin/a733/$board/boot0_sdcard.fex"
		[ -f "$boot0" ] || {
			echo "ci-firmware-build: missing $boot0" >&2
			exit 1
		}
	done
	[ -f "$sdkRoot/awbin/bin/a733/u-boot-header.bin" ] || {
		echo "ci-firmware-build: missing u-boot-header.bin" >&2
		exit 1
	}
	[ -f "$sdkRoot/awbin/scripts/bootpackage.py" ] || {
		echo "ci-firmware-build: missing bootpackage.py" >&2
		exit 1
	}
	clone_dep trusted-firmware-a
	clone_dep optee_os
	clone_dep u-boot
	build_uboot_pr
	;;
buildroot)
	rootfs_boards --optee buildroot br2
	run_build --no-optee demo_aiot_a733_v3 buildroot build br2
	;;
ubuntu)
	rootfs_boards --optee ubuntu ubuntu
	;;
debian)
	rootfs_boards --optee debian debian
	;;
openwrt)
	rootfs_boards --optee openwrt openwrt
	;;
meta-opentina)
	rootfs_boards --optee yocto yocto
	;;
esac

echo "component ok: $project"
