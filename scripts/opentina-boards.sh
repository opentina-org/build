# SPDX-License-Identifier: MIT
# Copyright (c) 2019-2026 Allwinner Technology Co., Ltd.
# Shared board / rootfs helpers (sourced by build.sh).

# Declared root filesystem types (extend when implementing).
opentina_rootfs_types=(buildroot debian ubuntu yocto openwrt)

opentina_rootfs_is_known() {
	local t="$1"
	for x in "${opentina_rootfs_types[@]}"; do
		[ "$x" = "$t" ] && return 0
	done
	return 1
}

# Print parent dir basename under configs/ for the given BOARD_NAME, or nothing.
opentina_config_dir_for_board_name() {
	local want="$1"
	local found="" n=0 d bn
	for cfg in "$OPENTINA_BUILD_ROOT"/configs/*/config; do
		[ -f "$cfg" ] || continue
		bn=$(grep -E '^[[:space:]]*BOARD_NAME=' "$cfg" | head -1 | cut -d= -f2-)
		bn=${bn#\"}
		bn=${bn%\"}
		bn=${bn#\'}
		bn=${bn%\'}
		bn=$(printf '%s' "$bn" | tr -d '[:space:]')
		[ "$bn" = "$want" ] || continue
		d=$(dirname -- "$cfg")
		found=$(basename -- "$d")
		n=$((n + 1))
	done
	if [ "$n" -eq 1 ]; then
		printf '%s' "$found"
		return 0
	fi
	if [ "$n" -gt 1 ]; then
		echo "opentina: duplicate BOARD_NAME \"$want\" under configs/" 1>&2
		return 2
	fi
	return 1
}

opentina_list_targets() {
	local cfg bn pretty
	blue_msg "Board targets (BOARD_NAME from each configs/*/config):"
	for cfg in "$OPENTINA_BUILD_ROOT"/configs/*/config; do
		[ -f "$cfg" ] || continue
		# shellcheck source=/dev/null
		. "$cfg"
		printf '  %-24s%s\n' "$BOARD_NAME" "${PRETTY_NAME:-}"
	done
	echo
	blue_msg "Root filesystem types:"
	echo "  buildroot"
	echo "  debian      (sources/debian → output/<BOARD>/rootfs.ext2)"
	echo "  ubuntu      (sources/ubuntu → output/<BOARD>/rootfs.ext2)"
	echo "  yocto       (sources/meta-opentina → output/<BOARD>/rootfs.ext2)"
	echo "  openwrt     (sources/openwrt → output/<BOARD>/rootfs.ext2)"
}

# Toolchain: same approach as build2/scripts/build-sdcard-image.sh — one AArch64
# GNU triple for TF-A, U-Boot, and Linux (e.g. gcc-aarch64-linux-gnu on Debian/Ubuntu).
# Override order: OPENTINA_CROSS_COMPILE (board config) > CROSS_COMPILE (env) > PATH scan.
opentina_cross_compile() {
	local p
	if [ -n "${OPENTINA_CROSS_COMPILE:-}" ]; then
		p="$OPENTINA_CROSS_COMPILE"
		command -v "${p}gcc" >/dev/null 2>&1 || {
			echo "opentina: OPENTINA_CROSS_COMPILE=$p but ${p}gcc not in PATH" 1>&2
			return 1
		}
		printf '%s' "$p"
		return 0
	fi
	if [ -n "${CROSS_COMPILE:-}" ]; then
		p="$CROSS_COMPILE"
		command -v "${p}gcc" >/dev/null 2>&1 || {
			echo "opentina: CROSS_COMPILE=$p but ${p}gcc not in PATH" 1>&2
			return 1
		}
		printf '%s' "$p"
		return 0
	fi
	for p in aarch64-linux-gnu- aarch64-none-linux-gnu-; do
		command -v "${p}gcc" >/dev/null 2>&1 || continue
		printf '%s' "$p"
		return 0
	done
	echo "opentina: no AArch64 cross compiler in PATH (install gcc-aarch64-linux-gnu, or set OPENTINA_CROSS_COMPILE / CROSS_COMPILE)" 1>&2
	return 1
}
