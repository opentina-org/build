# SPDX-License-Identifier: MIT
# Copyright (c) 2019-2026 Allwinner Technology Co., Ltd.
# Shared board / rootfs helpers (sourced by build.sh).

# Declared root filesystem types (extend when implementing).
opentina_rootfs_types=(buildroot debian ubuntu yocto openwrt)

# OP-TEE is optional for the whole project (BL32, kernel driver, TAs, userspace).
# Resolution: CLI --optee/--no-optee or env OPENTINA_OPTEE, then board
#   OPENTINA_OPTEE="${OPENTINA_OPTEE:-1}", default on.
opentina_optee_enabled() {
	case "${OPENTINA_OPTEE:-1}" in
	1 | y | Y | yes | YES | on | ON) return 0 ;;
	*) return 1 ;;
	esac
}

# Fingerprint of options that invalidate .done.* resume markers.
opentina_build_fingerprint() {
	local tee=0 profile="${OPENTINA_PROFILE:-}"
	opentina_optee_enabled && tee=1
	printf 'rootfs=%s\nprofile=%s\noptee=%s\n' \
		"${OPENTINA_ROOTFS:-buildroot}" "$profile" "$tee"
}

# Compact stamp for a git tree: HEAD + dirty worktree/index hash (empty if clean).
# Untracked-but-not-ignored files flip the dirty bit so local drops still rebuild.
opentina_git_tree_stamp() {
	local dir="$1" head dirty
	[ -e "$dir/.git" ] || {
		# Non-git path: fall back to recursive mtime/size digest (best-effort).
		if [ -d "$dir" ]; then
			find "$dir" -type f -printf '%P\t%T@\t%s\n' 2>/dev/null |
				sort | sha256sum | awk '{print "mtime:" substr($1,1,16)}'
		else
			printf 'missing'
		fi
		return 0
	}
	head="$(git -C "$dir" rev-parse HEAD 2>/dev/null || echo unknown)"
	dirty="$(git -C "$dir" status --porcelain=v1 2>/dev/null || true)"
	if [ -z "$dirty" ]; then
		printf '%s' "$head"
		return 0
	fi
	# Hash tracked diffs + the porcelain list (covers untracked names).
	printf '%s+dirty:%s' "$head" "$(
		{
			printf '%s\n' "$dirty"
			git -C "$dir" diff 2>/dev/null || true
			git -C "$dir" diff --cached 2>/dev/null || true
		} | sha256sum | awk '{print substr($1,1,16)}'
	)"
}

# sha256 of listed files that exist (order-stable). Missing files → "0".
opentina_files_stamp() {
	local f
	{
		for f in "$@"; do
			if [ -f "$f" ]; then
				# path + content so renames/edits both matter
				printf '%s\t' "$f"
				sha256sum "$f" | awk '{print $1}'
			else
				printf '%s\tmissing\n' "$f"
			fi
		done
	} | sha256sum | awk '{print substr($1,1,16)}'
}

# Build-repo files that define how components are built / packed. Edits here
# must invalidate resume the same way source-tree edits do.
opentina_recipe_scripts_stamp() {
	opentina_files_stamp \
		"$OPENTINA_BUILD_ROOT/scripts/recipes.sh" \
		"$OPENTINA_BUILD_ROOT/scripts/opentina-boards.sh" \
		"$OPENTINA_BUILD_ROOT/scripts/custom-pkg.sh" \
		"$OPENTINA_BUILD_ROOT/scripts/pack-u-boot.sh"
}

# Glob helper: stamp every regular file under dirs (sorted paths). Empty → "none".
opentina_dirs_stamp() {
	local dir f
	local -a found=()
	for dir in "$@"; do
		[ -d "$dir" ] || continue
		while IFS= read -r -d '' f; do
			found+=("$f")
		done < <(find "$dir" -type f -print0 2>/dev/null | sort -z)
	done
	if [ ${#found[@]} -eq 0 ]; then
		printf 'none'
		return 0
	fi
	opentina_files_stamp "${found[@]}"
}

# Inputs that affect a given build component. Printed as "key=value" lines.
# Includes both sources/ trees and the build-repo recipes/config that drive them.
opentina_component_stamp() {
	local comp="$1"
	local sdk="${sdkRoot:-$OPENTINA_BUILD_ROOT/sources}"
	local cfgdir="${boardConfigDir:-}"
	local common="$OPENTINA_BUILD_ROOT/configs/common"
	local board="$OPENTINA_BUILD_ROOT/configs/$cfgdir"

	printf 'comp=%s\n' "$comp"
	# Shared: recipe scripts in this build repo (build_*/clean_* implementations).
	printf 'recipes=%s\n' "$(opentina_recipe_scripts_stamp)"
	case "$comp" in
	optee)
		printf 'src=%s\n' "$(opentina_git_tree_stamp "$sdk/optee_os")"
		;;
	atf)
		printf 'src=%s\n' "$(opentina_git_tree_stamp "$sdk/trusted-firmware-a")"
		printf 'optee=%s\n' "${OPENTINA_OPTEE:-1}"
		;;
	uboot)
		printf 'src=%s\n' "$(opentina_git_tree_stamp "$sdk/u-boot")"
		printf 'awbin=%s\n' "$(opentina_git_tree_stamp "$sdk/awbin")"
		printf 'cfg=%s\n' "$(opentina_files_stamp "$board/config")"
		printf 'optee=%s\n' "${OPENTINA_OPTEE:-1}"
		;;
	linux)
		printf 'src=%s\n' "$(opentina_git_tree_stamp "$sdk/linux")"
		printf 'frags=%s\n' "$(opentina_files_stamp \
			"$common/linux-common.fragment" \
			"$common/linux-optee.fragment" \
			"$common/linux-systemd.fragment" \
			"$common/linux-openwrt.fragment" \
			"$board/config")"
		printf 'install=%s\n' "$(opentina_files_stamp \
			"$common/install-linux-modules.sh" \
			"$common/install-linux-modules-into-image.sh")"
		printf 'rootfs=%s\noptee=%s\n' "${OPENTINA_ROOTFS:-buildroot}" "${OPENTINA_OPTEE:-1}"
		;;
	br2)
		printf 'src=%s\n' "$(opentina_git_tree_stamp "$sdk/buildroot")"
		printf 'cfg=%s\n' "$(opentina_files_stamp \
			"$board/${BUILDROOT_DEFCONFIG:-br2_opentina.defconfig}" \
			"$common/br2-hmi.fragment" \
			"$common/br2-post-build.sh" \
			"$common/install-optee-ta.sh" \
			"$common/install-powervr-firmware.sh" \
			"$common/install-opentina-hmi.sh" \
			"$common/install-linux-modules.sh" \
			"$board/config")"
		printf 'patches=%s\n' "$(opentina_dirs_stamp "$common/br2-global-patches")"
		printf 'profile=%s\noptee=%s\n' "${OPENTINA_BR2_PROFILE:-lite}" "${OPENTINA_OPTEE:-1}"
		;;
	ubuntu)
		printf 'src=%s\n' "$(opentina_git_tree_stamp "$sdk/ubuntu")"
		printf 'overlay=%s\n' "$(opentina_files_stamp \
			"$common/install-linux-modules-into-image.sh" \
			"$common/install-optee-ta.sh" \
			"$common/install-powervr-firmware.sh" \
			"$board/config")"
		printf 'profile=%s\n' "${OPENTINA_UBUNTU_PROFILE:-lite}"
		;;
	debian)
		printf 'src=%s\n' "$(opentina_git_tree_stamp "$sdk/debian")"
		printf 'overlay=%s\n' "$(opentina_files_stamp \
			"$common/install-linux-modules-into-image.sh" \
			"$common/install-optee-ta.sh" \
			"$common/install-powervr-firmware.sh" \
			"$board/config")"
		printf 'profile=%s\n' "${OPENTINA_DEBIAN_PROFILE:-lite}"
		;;
	yocto)
		printf 'src=%s\n' "$(opentina_git_tree_stamp "$sdk/meta-opentina")"
		printf 'overlay=%s\n' "$(opentina_files_stamp \
			"$common/install-linux-modules-into-image.sh" \
			"$common/install-optee-ta.sh" \
			"$common/install-powervr-firmware.sh" \
			"$board/config")"
		printf 'profile=%s\n' "${OPENTINA_YOCTO_PROFILE:-minimal}"
		;;
	openwrt)
		printf 'src=%s\n' "$(opentina_git_tree_stamp "${OPENTINA_OPENWRT_DIR:-$sdk/openwrt}")"
		printf 'cfg=%s\n' "$(opentina_files_stamp \
			"$board/${OPENWRT_CONFIG:-openwrt.config}" \
			"$board/config" \
			"$common/install-openwrt-overlay.sh" \
			"$common/install-optee-ta.sh" \
			"$common/install-powervr-firmware.sh")"
		# Common + board OpenWrt patches and rootfs overlay files.
		local ow_patches=()
		shopt -s nullglob
		ow_patches+=("$common"/openwrt-patches/*.patch)
		ow_patches+=("$board"/openwrt-patches/*.patch)
		shopt -u nullglob
		if [ ${#ow_patches[@]} -gt 0 ]; then
			printf 'patches=%s\n' "$(opentina_files_stamp "${ow_patches[@]}")"
		else
			printf 'patches=none\n'
		fi
		printf 'files=%s\n' "$(opentina_dirs_stamp "$common/openwrt-files")"
		;;
	bootfs)
		printf 'linux_out=%s\n' "$(opentina_files_stamp \
			"${outDir%/}/Image.gz" \
			"${outDir%/}/${FDT_NAME:-}")"
		printf 'cfg=%s\n' "$(opentina_files_stamp "$board/config")"
		printf 'root=%s\n' "${EXTLINUX_ROOT:-root=/dev/mmcblk0p4 rw rootwait}"
		printf 'rootfs=%s\n' "${OPENTINA_ROOTFS:-buildroot}"
		;;
	image)
		printf 'inputs=%s\n' "$(opentina_files_stamp \
			"${outDir%/}/u-boot.fex" \
			"${outDir%/}/rootfs.ext2" \
			"${outDir%/}/boot.img" \
			"$board/partitions.cfg" \
			"$sdk/awbin/bin/a733/${BOARD_NAME:-}/boot0_sdcard.fex")"
		# boot.img may be produced by genimage; also stamp the bootfs tree.
		printf 'bootfs=%s\n' "$(opentina_files_stamp \
			"${outDir%/}/root/boot/vmlinuz" \
			"${outDir%/}/root/boot/extlinux/extlinux.conf" \
			"${outDir%/}/root/boot/${FDT_NAME:-}")"
		;;
	*)
		# Custom packages / unknown: stamp matching sources/<comp> if present.
		if [ -d "$sdk/$comp" ]; then
			printf 'src=%s\n' "$(opentina_git_tree_stamp "$sdk/$comp")"
		else
			printf 'src=unknown\n'
		fi
		;;
	esac
}

# True if .done.<comp> exists and matches the current stamp.
opentina_component_is_current() {
	local comp="$1"
	local marker="${outDir%/}/.done.$comp"
	local cur prev
	[ -f "$marker" ] || return 1
	cur="$(opentina_component_stamp "$comp")"
	prev="$(cat "$marker")"
	[ "$prev" = "$cur" ]
}

# Components that must be rebuilt when $1 is rebuilt (downstream consumers).
opentina_component_invalidate_downstream() {
	local comp="$1"
	local rootfs_comp
	case "${OPENTINA_ROOTFS:-buildroot}" in
	ubuntu) rootfs_comp=ubuntu ;;
	debian) rootfs_comp=debian ;;
	yocto) rootfs_comp=yocto ;;
	openwrt) rootfs_comp=openwrt ;;
	*) rootfs_comp=br2 ;;
	esac
	case "$comp" in
	optee) printf '%s\n' uboot image ;;
	atf) printf '%s\n' uboot image ;;
	uboot) printf '%s\n' image ;;
	linux) printf '%s\n' bootfs image "$rootfs_comp" ;;
	br2 | ubuntu | debian | yocto | openwrt) printf '%s\n' image ;;
	bootfs) printf '%s\n' image ;;
	image) ;;
	*) printf '%s\n' image ;;
	esac
}

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
	echo
	blue_msg "OP-TEE (optional, default on):"
	echo "  ./build.sh --optee <BOARD> build     # BL32 + kernel driver + TAs"
	echo "  ./build.sh --no-optee <BOARD> build  # ATF SPD=none, no BL32 / TAs"
	echo "  OPENTINA_OPTEE=0 ./build.sh <BOARD> build"
	echo
	blue_msg "Rootfs profile (optional, before the board name):"
	echo "  ./build.sh --profile <NAME> <BOARD> [ROOTFS] build"
	echo "  buildroot: lite (default) | hmi"
	echo "  ubuntu, debian: lite (default) | desktop"
	echo "  yocto: minimal (default) | qt | hmi"
	echo "  openwrt: no profile"
	echo
	blue_msg "Incremental / resume (optional):"
	echo "  Full-chain build resumes by default (skips only if .done.* stamp matches sources)."
	echo "  Editing sources/config invalidates that component (and its downstream)."
	echo "  ./build.sh --force <BOARD> build     # rebuild every selected component"
	echo "  ./build.sh --resume <BOARD> build linux  # skip linux if stamp still current"
	echo "  ./build.sh <BOARD> status           # show .done.* / stale and fingerprint"
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
