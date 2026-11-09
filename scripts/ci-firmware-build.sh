#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Component-only CI (no sdcard.img). Used by firmware-component.yml.
# Each invocation is one build. `matrix` prints the job list; `run` builds one.
#
# Coverage follows the build-repo PR subset: demo × rootfs/optee, demo
# buildroot/no-optee, a7a buildroot/optee — plus linux OpenWrt fragments —
# and, for rootfs repos, every profile. Rootfs jobs also pack sdcard.img.
#
# Environment (run):
#   OPENTINA_BUILD_ROOT    Checkout of the build repo
#   FIRMWARE_SRC           Checkout of the PR (default: $PWD)
#   OPENTINA_GH_TOKEN      Optional PAT for private opentina-org clones
#   OPENTINA_CI_BOARD      demo_aiot_a733_v3 | radxa_a7a
#   OPENTINA_CI_ROOTFS     buildroot | ubuntu | debian | openwrt | yocto
#   OPENTINA_CI_TEE        optee | no-optee
#   OPENTINA_CI_PROFILE    buildroot lite|hmi; ubuntu/debian lite|desktop;
#                          yocto minimal|qt|hmi. Empty when the target has none.
#   OPENTINA_CI_COMPONENTS Words passed to build.sh after `build` (e.g. "br2"
#                          or "optee atf uboot")
#   OPENTINA_CI_PACK_IMAGE true: clone the boot chain and also build
#                          optee/atf/uboot/linux/bootfs/image so sdcard.img exists

set -euo pipefail

script_dir="$(dirname -- "$(realpath -- "$0")")"
OPENTINA_BUILD_ROOT="${OPENTINA_BUILD_ROOT:-$(dirname -- "$script_dir")}"
export OPENTINA_BUILD_ROOT

usage() {
	echo "usage: ci-firmware-build.sh matrix <project> | run <project>" >&2
	exit 2
}

mode="${1:-}"
case "$mode" in
matrix | run) shift ;;
*) usage ;;
esac

normalize_project() {
	case "$1" in
	linux) printf '%s\n' linux ;;
	u-boot | uboot) printf '%s\n' u-boot ;;
	optee_os | optee) printf '%s\n' optee_os ;;
	trusted-firmware-a | atf | tf-a) printf '%s\n' trusted-firmware-a ;;
	awbin) printf '%s\n' awbin ;;
	buildroot | br2) printf '%s\n' buildroot ;;
	ubuntu) printf '%s\n' ubuntu ;;
	debian) printf '%s\n' debian ;;
	openwrt) printf '%s\n' openwrt ;;
	meta-opentina | yocto) printf '%s\n' meta-opentina ;;
	*)
		echo "ci-firmware-build: unsupported project ${1:-<empty>}" >&2
		exit 1
		;;
	esac
}

project="$(normalize_project "${1:-${FIRMWARE_PROJECT:-}}")"

if [ "$mode" = matrix ]; then
	PROJECT="$project" python3 - <<'PY'
import json, os

project = os.environ["PROJECT"]
demo = "demo_aiot_a733_v3"
a7a = "radxa_a7a"
boards = [demo, a7a]
short = {demo: "demo", a7a: "a7a"}

def row(board, rootfs, tee, components, profile="", ccache=True, yocto=False, show_rootfs=False, pack_image=False):
    parts = [short.get(board, board)]
    if show_rootfs:
        parts.append(rootfs)
    parts.append(tee)
    if profile:
        parts.append(profile)
    return {
        "label": " / ".join(parts),
        "project": project,
        "board": board,
        "rootfs": rootfs,
        "tee": tee,
        "profile": profile,
        "components": components,
        "ccache": "true" if ccache else "false",
        "yocto": "true" if yocto else "false",
        "pack_image": "true" if pack_image else "false",
    }

rows = []
if project == "linux":
    for rootfs, tees in (
        ("buildroot", ("optee", "no-optee")),
        ("ubuntu", ("optee",)),
        ("openwrt", ("optee",)),
    ):
        for tee in tees:
            for board in boards:
                rows.append(row(board, rootfs, tee, "linux", show_rootfs=True))
elif project == "trusted-firmware-a":
    for tee in ("optee", "no-optee"):
        rows.append(row(demo, "buildroot", tee, "atf"))
elif project == "optee_os":
    rows.append(row(demo, "buildroot", "optee", "optee"))
elif project in ("u-boot", "awbin"):
    rows.append(row(demo, "buildroot", "optee", "optee atf uboot"))
    rows.append(row(a7a, "buildroot", "optee", "optee atf uboot"))
    rows.append(row(demo, "buildroot", "no-optee", "atf uboot"))
elif project == "buildroot":
    for profile in ("lite", "hmi"):
        for board in boards:
            rows.append(row(board, "buildroot", "optee", "br2", profile, pack_image=True))
        rows.append(row(demo, "buildroot", "no-optee", "br2", profile, pack_image=True))
elif project in ("ubuntu", "debian"):
    for profile in ("lite", "desktop"):
        for board in boards:
            rows.append(row(board, project, "optee", project, profile, ccache=False, pack_image=True))
elif project == "openwrt":
    for board in boards:
        rows.append(row(board, "openwrt", "optee", "openwrt", pack_image=True))
elif project == "meta-opentina":
    for profile in ("minimal", "qt", "hmi"):
        for board in boards:
            rows.append(row(board, "yocto", "optee", "yocto", profile, yocto=True, pack_image=True))
else:
    raise SystemExit(f"ci-firmware-build: no matrix for {project}")

print(json.dumps({"include": rows}, separators=(",", ":")))
PY
	exit 0
fi

# run
FIRMWARE_SRC="$(realpath -- "${FIRMWARE_SRC:-$PWD}")"
sdkRoot="$OPENTINA_BUILD_ROOT/sources"
export sdkRoot
mkdir -p "$sdkRoot"

board="${OPENTINA_CI_BOARD:?ci-firmware-build: OPENTINA_CI_BOARD is required}"
rootfs="${OPENTINA_CI_ROOTFS:?ci-firmware-build: OPENTINA_CI_ROOTFS is required}"
tee="${OPENTINA_CI_TEE:?ci-firmware-build: OPENTINA_CI_TEE is required}"
components="${OPENTINA_CI_COMPONENTS:?ci-firmware-build: OPENTINA_CI_COMPONENTS is required}"
profile="${OPENTINA_CI_PROFILE:-}"

case "$tee" in
optee) tee_flag=--optee ;;
no-optee) tee_flag=--no-optee ;;
*)
	echo "ci-firmware-build: tee must be optee or no-optee (got: $tee)" >&2
	exit 1
	;;
esac

case "$project" in
buildroot)
	case "$profile" in
	lite | hmi) ;;
	*)
		echo "ci-firmware-build: buildroot profile must be lite or hmi (got: ${profile:-<empty>})" >&2
		exit 1
		;;
	esac
	;;
ubuntu | debian)
	case "$profile" in
	lite | desktop) ;;
	*)
		echo "ci-firmware-build: $project profile must be lite or desktop (got: ${profile:-<empty>})" >&2
		exit 1
		;;
	esac
	;;
meta-opentina)
	case "$profile" in
	minimal | qt | hmi) ;;
	*)
		echo "ci-firmware-build: yocto profile must be minimal, qt or hmi (got: ${profile:-<empty>})" >&2
		exit 1
		;;
	esac
	;;
*)
	if [ -n "$profile" ]; then
		echo "ci-firmware-build: $project has no --profile (got: $profile)" >&2
		exit 1
	fi
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
	local -a cmd=("$OPENTINA_BUILD_ROOT/build.sh")
	if [ -n "$profile" ]; then
		cmd+=(--profile "$profile")
	fi
	echo "========== ${cmd[*]} $* =========="
	"${cmd[@]}" "$@"
}

link_self "$project"

case "$project" in
u-boot)
	clone_dep trusted-firmware-a
	clone_dep optee_os
	clone_dep awbin
	;;
awbin)
	for aw_board in demo_aiot_a733_v3 radxa_a7a; do
		boot0="$sdkRoot/awbin/bin/a733/$aw_board/boot0_sdcard.fex"
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
	;;
esac

read -r -a comp_args <<< "$components"
if [ "${OPENTINA_CI_PACK_IMAGE:-}" = true ]; then
	# PR tree is the rootfs. Boot chain comes from tina-dev so the job can
	# pack a flashable sdcard.img around that rootfs.
	for dep in linux u-boot trusted-firmware-a optee_os awbin; do
		clone_dep "$dep"
	done
	if [ "$tee" = optee ]; then
		comp_args=(optee atf uboot linux "${comp_args[@]}" bootfs image)
	else
		comp_args=(atf uboot linux "${comp_args[@]}" bootfs image)
	fi
fi
run_build "$tee_flag" "$board" "$rootfs" build "${comp_args[@]}"
echo "component ok: $project $board $rootfs $tee ${profile:-default}"
