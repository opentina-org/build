#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2019-2026 Allwinner Technology Co., Ltd.

availableComponents=(optee atf uboot linux br2 bootfs image)

OPENTINA_BUILD_ROOT="$(dirname -- "$(realpath -- "$0")")"
export OPENTINA_BUILD_ROOT

# Firmware trees live under this build repo (clone via scripts/repo_clone.sh).
sdkRoot="$OPENTINA_BUILD_ROOT/sources"
export sdkRoot

# --- Optional leading flags (stripped before board/init/targets parsing) ---
# --docker is host-only. --optee/--no-optee, --profile, --force/--resume
# are re-passed into the container; a non-exported shell assignment would be lost
# at exec docker-exec.sh.
optee_cli_flags=()
profile_cli_flags=()
resume_cli_flags=()
while [ $# -gt 0 ]; do
	case "$1" in
	--docker-shell)
		OPENTINA_DOCKER_SHELL=1
		shift
		break
		;;
	--docker)
		OPENTINA_DOCKER=1
		shift
		;;
	--optee)
		OPENTINA_OPTEE=1
		export OPENTINA_OPTEE
		optee_cli_flags+=(--optee)
		shift
		;;
	--no-optee)
		OPENTINA_OPTEE=0
		export OPENTINA_OPTEE
		optee_cli_flags+=(--no-optee)
		shift
		;;
	--profile)
		if [ $# -lt 2 ] || [ -z "${2:-}" ] || [ "${2#-}" != "$2" ]; then
			echo "--profile needs a name (buildroot: lite|hmi; ubuntu/debian: lite|desktop; yocto: minimal|qt|hmi)." >&2
			exit 1
		fi
		OPENTINA_PROFILE_CLI=$2
		profile_cli_flags=(--profile "$2")
		shift 2
		;;
	--profile=*)
		OPENTINA_PROFILE_CLI=${1#--profile=}
		if [ -z "$OPENTINA_PROFILE_CLI" ]; then
			echo "--profile needs a name (buildroot: lite|hmi; ubuntu/debian: lite|desktop; yocto: minimal|qt|hmi)." >&2
			exit 1
		fi
		profile_cli_flags=(--profile "$OPENTINA_PROFILE_CLI")
		shift
		;;
	--force | --rebuild)
		OPENTINA_FORCE_BUILD=1
		export OPENTINA_FORCE_BUILD
		resume_cli_flags+=(--force)
		shift
		;;
	--resume)
		OPENTINA_RESUME=1
		export OPENTINA_RESUME
		resume_cli_flags+=(--resume)
		shift
		;;
	--no-resume)
		OPENTINA_RESUME=0
		export OPENTINA_RESUME
		resume_cli_flags+=(--no-resume)
		shift
		;;
	*)
		break
		;;
	esac
done

# Interactive shell in the build image (same mounts as --docker builds).
if [ -n "${OPENTINA_DOCKER_SHELL:-}" ]; then
	if [ -n "${OPENTINA_SKIP_DOCKER:-}" ]; then
		echo "OPENTINA_SKIP_DOCKER is set; refusing --docker-shell." >&2
		exit 1
	fi
	if [ -n "${OPENTINA_IN_DOCKER:-}" ] || [ -e /.dockerenv ]; then
		echo "Already inside a container." >&2
		exit 1
	fi
	command -v docker >/dev/null 2>&1 || {
		echo "docker: not found." >&2
		exit 127
	}
	exec "$OPENTINA_BUILD_ROOT/scripts/docker-exec.sh" --shell "$@"
fi

# Opt-in: build inside Ubuntu 24.04 (OPENTINA_DOCKER=1 or one or more --docker flags).
if [ -z "${OPENTINA_SKIP_DOCKER:-}" ] && [ -z "${OPENTINA_IN_DOCKER:-}" ] && [ ! -e /.dockerenv ] &&
	[ -n "${OPENTINA_DOCKER:-}" ] && [ "${OPENTINA_DOCKER}" != "0" ] &&
	command -v docker >/dev/null 2>&1; then
	exec "$OPENTINA_BUILD_ROOT/scripts/docker-exec.sh" \
		"${optee_cli_flags[@]}" "${profile_cli_flags[@]}" \
		"${resume_cli_flags[@]}" "$@"
fi

if [ -n "${OPENTINA_DOCKER:-}" ] && [ "${OPENTINA_DOCKER}" != "0" ] &&
	[ -z "${OPENTINA_SKIP_DOCKER:-}" ] && [ -z "${OPENTINA_IN_DOCKER:-}" ] && [ ! -e /.dockerenv ] &&
	! command -v docker >/dev/null 2>&1; then
	echo "OPENTINA_DOCKER=1 but docker is not in PATH; staying on host." >&2
fi

msg() {
	echo "$1" 2>&1
}

if [ -t 1 ]; then
	red_msg() {
		echo -ne "\033[31m"
		msg "$1"
		echo -ne "\033[39m"
	}

	yellow_msg() {
		echo -ne "\033[33m"
		msg "$1"
		echo -ne "\033[39m"
	}

	blue_msg() {
		echo -ne "\033[34m"
		msg "$1"
		echo -ne "\033[39m"
	}
else
	red_msg() {
		msg "$1"
	}

	yellow_msg() {
		msg "$1"
	}

	blue_msg() {
		msg "$1"
	}
fi

# shellcheck source=scripts/opentina-boards.sh
source "$OPENTINA_BUILD_ROOT/scripts/opentina-boards.sh"

error() {
	red_msg "$1"
	exit 1
}

usage() {
	[ "$1" ] && msg "$1"

	echo "From $OPENTINA_BUILD_ROOT:"
	echo "  Host (default):"
	echo "    ./build.sh ..."
	echo "  Docker (Ubuntu 24.04 image, same repo mount):"
	echo "    ./build.sh --docker ...          # one-shot: prefix once"
	echo "    OPENTINA_DOCKER=1 ./build.sh ...   # or export for the session"
	echo "    ./build.sh --docker-shell        # interactive shell in the image"
	echo "    OPENTINA_DOCKER_IMAGE=tag:local ...  # override image name"
	echo "    OPENTINA_DOCKER_HOSTNAME=name ...  # container hostname (default opentina)"
	echo "  Force host even with OPENTINA_DOCKER in env:"
	echo "    OPENTINA_SKIP_DOCKER=1 ./build.sh ..."
	echo
	echo "  OP-TEE (optional; default on):"
	echo "    ./build.sh --optee ...           # enable BL32 + kernel driver + TAs"
	echo "    ./build.sh --no-optee ...        # ATF SPD=none, no BL32 / TAs"
	echo "    OPENTINA_OPTEE=0 ./build.sh ...  # same as --no-optee (board config may set a default)"
	echo
	echo "  Rootfs profile (optional; written before the board name):"
	echo "    ./build.sh --profile <NAME> <BOARD> [ROOTFS] build"
	echo "    buildroot: lite (default) | hmi"
	echo "    ubuntu, debian: lite (default) | desktop"
	echo "    yocto: minimal (default) | qt | hmi"
	echo "    openwrt: no profile"
	echo "    Same names as OPENTINA_BR2_PROFILE / OPENTINA_UBUNTU_PROFILE /"
	echo "    OPENTINA_DEBIAN_PROFILE / OPENTINA_YOCTO_PROFILE (CLI wins)."
	echo
	echo "  Incremental / checkpoint resume (optional; before the board name):"
	echo "    Full-chain build resumes by default: skips a component only when"
	echo "    .done.<comp> matches the current source/config stamp (code edits rebuild)."
	echo "    ./build.sh --force <BOARD> build     # rebuild all selected components"
	echo "    ./build.sh --resume <BOARD> build X  # skip X if stamp still current"
	echo "    ./build.sh --no-resume <BOARD> build # always rebuild (legacy)"
	echo "    Explicit COMPONENT list rebuilds those components unless --resume."
	echo
	echo "  ./build.sh targets | list"
	echo "      List board targets (BOARD_NAME) and root filesystem types"
	echo
	echo "  ./build.sh init [MANIFEST_XML]"
	echo "      Clone sources (default: scripts/opentina-manifest.xml)"
	echo
	echo "  ./build.sh update [MANIFEST_XML]"
	echo "      Fast-forward sources already on the manifest branch to origin."
	echo "      Repos on another branch are listed and left unchanged."
	echo
	echo "  ./build.sh <BOARD_NAME> <build|clean|status> [COMPONENT]"
	echo "  ./build.sh <BOARD_NAME> <ROOTFS> <build|clean|status> [COMPONENT]"
	echo "      ROOTFS: buildroot (default if omitted), debian, ubuntu, yocto, openwrt"
	echo
	echo "	Action is build, clean, or status"
	echo
	echo "	Available components"
	echo "		${availableComponents[@]}"

	exit 1
}

requires() {
	[ -f "${outDir%/}/.done.${1}" ] ||
	error "Building component \"$gThisComponent\" requires \"$1\", which hasn't been built yet."
}

if [ "$#" -eq 0 ]; then
	opentina_list_targets
	echo
	msg "Run: ./build.sh <BOARD_NAME> [ROOTFS] <build|clean|status> [COMPONENT]"
	msg "Use ./build.sh targets to show this list again."
	exit 0
fi

if [ "$1" = targets ] || [ "$1" = list ]; then
	opentina_list_targets
	exit 0
fi

if [ "${1:-}" = init ]; then
	shift
	if [ "${1:-}" ]; then
		manifest="$(realpath -- "$1")"
	else
		manifest="$(realpath -- "$OPENTINA_BUILD_ROOT/scripts/opentina-manifest.xml")"
	fi
	[ -f "$manifest" ] || error "Manifest not found: $manifest"
	exec "$OPENTINA_BUILD_ROOT/scripts/repo_clone.sh" --gitclone "$manifest"
fi

if [ "${1:-}" = update ]; then
	shift
	if [ "${1:-}" ]; then
		manifest="$(realpath -- "$1")"
	else
		manifest="$(realpath -- "$OPENTINA_BUILD_ROOT/scripts/opentina-manifest.xml")"
	fi
	[ -f "$manifest" ] || error "Manifest not found: $manifest"
	exec "$OPENTINA_BUILD_ROOT/scripts/repo_clone.sh" --update "$manifest"
fi

boardName="$1"
shift
[ "$boardName" ] || usage "Missing board name"

if ! boardConfigDir=$(opentina_config_dir_for_board_name "$boardName"); then
	rc=$?
	opentina_list_targets
	echo
	[ "$rc" = 2 ] && error "Duplicate BOARD_NAME \"$boardName\" under configs/"
	error "Unknown board BOARD_NAME \"$boardName\""
fi

if [ "${1:-}" = build ] || [ "${1:-}" = clean ] || [ "${1:-}" = status ]; then
	OPENTINA_ROOTFS=buildroot
	action=$1
	shift
elif opentina_rootfs_is_known "${1:-}"; then
	OPENTINA_ROOTFS=$1
	shift
	case "${1:-}" in
	build | clean | status)
		action=$1
		shift
		;;
	*)
		usage "Missing build|clean|status after rootfs type \"$OPENTINA_ROOTFS\""
		;;
	esac
else
	usage "Expected build|clean|status, or a rootfs (${opentina_rootfs_types[*]}) then build|clean|status"
fi

export OPENTINA_ROOTFS

# --profile selects the rootfs-specific variable the recipe already reads.
# OpenWrt has a single config and rejects the flag.
opentina_apply_rootfs_profile() {
	local profile="$1"
	case "$OPENTINA_ROOTFS" in
	buildroot)
		case "$profile" in
		lite | hmi) export OPENTINA_BR2_PROFILE="$profile" ;;
		*) error "buildroot --profile must be lite or hmi (got: $profile)" ;;
		esac
		;;
	ubuntu)
		case "$profile" in
		lite | desktop) export OPENTINA_UBUNTU_PROFILE="$profile" ;;
		*) error "ubuntu --profile must be lite or desktop (got: $profile)" ;;
		esac
		;;
	debian)
		case "$profile" in
		lite | desktop) export OPENTINA_DEBIAN_PROFILE="$profile" ;;
		*) error "debian --profile must be lite or desktop (got: $profile)" ;;
		esac
		;;
	yocto)
		case "$profile" in
		minimal | qt | hmi) export OPENTINA_YOCTO_PROFILE="$profile" ;;
		*) error "yocto --profile must be minimal, qt or hmi (got: $profile)" ;;
		esac
		;;
	openwrt)
		error "openwrt has no --profile (got: $profile)"
		;;
	*)
		error "unknown rootfs for --profile: $OPENTINA_ROOTFS"
		;;
	esac
}

if [ -n "${OPENTINA_PROFILE_CLI:-}" ]; then
	opentina_apply_rootfs_profile "$OPENTINA_PROFILE_CLI"
fi

opentina_rootfs_component() {
	case "$OPENTINA_ROOTFS" in
	ubuntu) printf '%s' ubuntu ;;
	debian) printf '%s' debian ;;
	yocto) printf '%s' yocto ;;
	openwrt) printf '%s' openwrt ;;
	*) printf '%s' br2 ;;
	esac
}

userComponents="$*"
explicitComponents=0
[ -n "$userComponents" ] && explicitComponents=1

# Setting up default building parameters
[ "$JOBS" ] || JOBS="$(nproc)"
outDir="$OPENTINA_BUILD_ROOT/output/$boardName/"
export outDir

# Setting up default make parameters
export MAKEFLAGS="$MAKEFLAGS -j$JOBS"

mkdir -p "$outDir"

source "$OPENTINA_BUILD_ROOT/configs/$boardConfigDir/config"

# Board config may set OPENTINA_OPTEE="${OPENTINA_OPTEE:-1}"; CLI/env already won.
if opentina_optee_enabled; then
	export OPENTINA_OPTEE=1
	export OPENTINA_OPTEE_EXPORT="${outDir%/}/optee"
	availableComponents=(optee atf uboot linux "$(opentina_rootfs_component)" bootfs image)
	blue_msg "OP-TEE: enabled (BL32 + kernel driver + TAs)"
else
	export OPENTINA_OPTEE=0
	unset OPENTINA_OPTEE_EXPORT
	availableComponents=(atf uboot linux "$(opentina_rootfs_component)" bootfs image)
	# Still clean leftover tee.bin / $O/optee when OP-TEE is off.
	if [ "$action" = clean ]; then
		availableComponents=(optee "${availableComponents[@]}")
	fi
	blue_msg "OP-TEE: disabled (ATF SPD=none, no BL32 / TAs)"
fi

case "$OPENTINA_ROOTFS" in
buildroot) OPENTINA_PROFILE="${OPENTINA_BR2_PROFILE:-lite}" ;;
ubuntu) OPENTINA_PROFILE="${OPENTINA_UBUNTU_PROFILE:-lite}" ;;
debian) OPENTINA_PROFILE="${OPENTINA_DEBIAN_PROFILE:-lite}" ;;
yocto) OPENTINA_PROFILE="${OPENTINA_YOCTO_PROFILE:-minimal}" ;;
*) OPENTINA_PROFILE="" ;;
esac
export OPENTINA_PROFILE
if [ -n "$OPENTINA_PROFILE" ]; then
	blue_msg "rootfs profile: $OPENTINA_PROFILE ($OPENTINA_ROOTFS)"
fi

component="$userComponents"
[ "$component" ] || component="${availableComponents[*]}"

# Resume policy:
#   full chain (no COMPONENT args): resume by default
#   explicit COMPONENT list: rebuild those unless --resume
#   --force / --rebuild: never skip
#   --no-resume: never skip
if [ -n "${OPENTINA_FORCE_BUILD:-}" ] && [ "${OPENTINA_FORCE_BUILD}" != "0" ]; then
	OPENTINA_RESUME=0
elif [ -z "${OPENTINA_RESUME+x}" ]; then
	if [ "$explicitComponents" -eq 0 ]; then
		OPENTINA_RESUME=1
	else
		OPENTINA_RESUME=0
	fi
fi
export OPENTINA_RESUME

opentina_clear_done_markers() {
	local c
	for c in "${availableComponents[@]}"; do
		rm -f "${outDir%/}/.done.$c"
	done
	# Also drop markers for rootfs components not in the active chain.
	rm -f "${outDir%/}"/.done.br2 "${outDir%/}"/.done.ubuntu "${outDir%/}"/.done.debian \
		"${outDir%/}"/.done.yocto "${outDir%/}"/.done.openwrt "${outDir%/}"/.done.optee
}

opentina_write_done_marker() {
	local comp="$1"
	opentina_component_stamp "$comp" >"${outDir%/}/.done.$comp"
}

opentina_invalidate_downstream() {
	local comp="$1" d
	while IFS= read -r d; do
		[ -n "$d" ] || continue
		if [ -f "${outDir%/}/.done.$d" ]; then
			yellow_msg "invalidate $d (downstream of $comp)"
			rm -f "${outDir%/}/.done.$d"
		fi
	done < <(opentina_component_invalidate_downstream "$comp")
}

opentina_sync_build_meta() {
	local meta="$outDir/.build-meta" fp prev
	fp="$(opentina_build_fingerprint)"
	# $(...) strips one trailing newline from both sides; compare that form.
	if [ -f "$meta" ]; then
		prev="$(cat "$meta")"
		if [ "$prev" = "$fp" ]; then
			return 0
		fi
		yellow_msg "Build options changed (rootfs/profile/optee); clearing .done.* resume markers"
		opentina_clear_done_markers
	fi
	# Restore the newline eaten by command substitution.
	printf '%s\n' "$fp" >"$meta"
	printf '%s\n' "$OPENTINA_ROOTFS" >"${outDir%/}/.rootfs"
}

opentina_print_status() {
	local c mark
	blue_msg "Build status for $boardName (rootfs=$OPENTINA_ROOTFS):"
	if [ -f "${outDir%/}/.build-meta" ]; then
		echo "  fingerprint:"
		sed 's/^/    /' "${outDir%/}/.build-meta"
		echo
	else
		echo "  fingerprint: (none yet)"
	fi
	echo "  disk image: sdcard.img"
	echo "  extlinux:   ${EXTLINUX_ROOT:-root=/dev/mmcblk0p4 rw rootwait}"
	echo "  components:"
	for c in "${availableComponents[@]}"; do
		if [ ! -f "${outDir%/}/.done.$c" ]; then
			mark="pending"
		elif opentina_component_is_current "$c"; then
			mark="done (current)"
		else
			mark="stale (sources/config changed)"
		fi
		printf '    %-12s %s\n' "$c" "$mark"
	done
	if [ -f "${outDir%/}/sdcard.img" ]; then
		echo "  artifact:   ${outDir%/}/sdcard.img ($(du -h "${outDir%/}/sdcard.img" | cut -f1))"
	else
		echo "  artifact:   ${outDir%/}/sdcard.img (missing)"
	fi
}

if [ "$action" = build ]; then
	for _c in $component; do
		if [ "$_c" = optee ] && ! opentina_optee_enabled; then
			error "OP-TEE is disabled (OPENTINA_OPTEE=0). Enable with --optee or OPENTINA_OPTEE=1."
		fi
	done
	unset _c
	opentina_sync_build_meta
	if [ "${OPENTINA_RESUME}" = "1" ]; then
		blue_msg "resume: enabled (skip only when .done.* stamp matches sources; use --force to rebuild all)"
	else
		blue_msg "resume: disabled (rebuild selected components)"
	fi
fi

if [ "$action" = status ]; then
	opentina_print_status
	exit 0
fi

source "$OPENTINA_BUILD_ROOT/scripts/recipes.sh"

for comp in ${component}; do
	todo="${action}_${comp}"
	gThisComponent="$comp"

	if ! declare -F "$todo" > /dev/null 2>/dev/null; then
		error "Action \"$action\" for component \"$comp\" isn't defined!"
	fi

	if [ "$action" = build ] && [ "${OPENTINA_RESUME}" = "1" ] && opentina_component_is_current "$comp"; then
		yellow_msg "========== skip $comp (resume: stamp current) =========="
		continue
	fi
	if [ "$action" = build ] && [ "${OPENTINA_RESUME}" = "1" ] && [ -f "${outDir%/}/.done.$comp" ]; then
		yellow_msg "========== rebuild $comp (sources/config changed since last build) =========="
	fi

	if [ -n "${OPENTINA_PROFILE:-}" ]; then
		blue_msg "========== $action component $comp (rootfs=$OPENTINA_ROOTFS profile=$OPENTINA_PROFILE) =========="
	else
		blue_msg "========== $action component $comp (rootfs=$OPENTINA_ROOTFS) =========="
	fi
	"$todo"
	cd "$OPENTINA_BUILD_ROOT"
	blue_msg "========== $action component $comp done ========"

	if [ "$action" = build ]; then
		opentina_invalidate_downstream "$comp"
		opentina_write_done_marker "$comp"
	else
		rm -f "${outDir%/}/.done.$comp"
	fi
done

if [ "$action" = build ]; then
	opentina_sync_build_meta
	blue_msg "Build finished. Disk image: ${outDir%/}/sdcard.img"
fi
