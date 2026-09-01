# SPDX-License-Identifier: MIT
# Copyright (c) 2019-2026 Allwinner Technology Co., Ltd.
opteePath="$sdkRoot/optee_os"

build_optee() {
	local cc tee_raw
	cc=$(opentina_cross_compile) || error "Set OPENTINA_CROSS_COMPILE or install gcc-aarch64-linux-gnu."

	[ -d "$opteePath" ] || error "Missing OP-TEE tree: $opteePath (./build.sh init)"

	cd "$opteePath"

	# tee-raw.bin: no OP-TEE v1 header; U-Boot FIT loads it at SUNXI_BL32_BASE.
	make PLATFORM=sunxi-sun60i_a733 \
		CROSS_COMPILE64="$cc" \
		CFG_TEE_CORE_LOG_LEVEL=2 \
		O="$outDir/optee" \
		|| error "OP-TEE build failed"

	tee_raw="$outDir/optee/core/tee-raw.bin"
	[ -f "$tee_raw" ] || error "Missing OP-TEE image: $tee_raw"
	cp "$tee_raw" "$outDir/tee.bin"
}

clean_optee() {
	rm -rf "$outDir/optee"
	rm -f "$outDir/tee.bin"
}

atfPath="$sdkRoot/trusted-firmware-a"

build_atf() {
	local cc
	cc=$(opentina_cross_compile) || error "Set OPENTINA_CROSS_COMPILE or install gcc-aarch64-linux-gnu (see build2/scripts/build-sdcard-image.sh)."

	cd "$atfPath"

	# SPD=opteed: BL31 hands off to preloaded BL32 (OP-TEE at DRAM base) then BL33.
	make PLAT=sun60i_a733 SPD=opteed CROSS_COMPILE="$cc" all || error "ATF build failed"
}

clean_atf() {
	local cc
	cc=$(opentina_cross_compile) || cc=aarch64-linux-gnu-
	cd "$atfPath"

	make PLAT=sun60i_a733 CROSS_COMPILE="$cc" clean
}

ubootPath="$sdkRoot/u-boot"
build_uboot() {
	requires "atf"
	requires "optee"

	local cc bl31 tee
	cc=$(opentina_cross_compile) || error "Set OPENTINA_CROSS_COMPILE or install gcc-aarch64-linux-gnu."
	bl31="$sdkRoot/trusted-firmware-a/build/sun60i_a733/release/bl31.bin"
	tee="$outDir/tee.bin"
	[ -f "$bl31" ] || error "Missing BL31: $bl31 (build atf first)"
	[ -f "$tee" ] || error "Missing TEE: $tee (build optee first)"

	cd "$ubootPath"

	# Match build2: same CROSS_COMPILE as TF-A/Linux; disable host-only mkeficapsule (gnutls).
	# TEE= is consumed by binman (-a tee-os-path) and packed into the SPL FIT as BL32.
	make CROSS_COMPILE="$cc" BL31="$bl31" TEE="$tee" "$UBOOT_CONFIG" || error "U-Boot defconfig failed"
	"$ubootPath/scripts/config" --file "$ubootPath/.config" --disable TOOLS_MKEFICAPSULE
	# SPL FIT (BL31+OP-TEE+U-Boot) is >1MiB; keep simple heap large enough.
	"$ubootPath/scripts/config" --file "$ubootPath/.config" \
		--set-val SPL_STACK_R_MALLOC_SIMPLE_LEN 0x200000
	make CROSS_COMPILE="$cc" BL31="$bl31" TEE="$tee" olddefconfig >/dev/null || error "U-Boot olddefconfig failed"
	make CROSS_COMPILE="$cc" BL31="$bl31" TEE="$tee" || error "U-Boot build failed"

	[ -f "$ubootPath/u-boot-sunxi-with-spl.bin" ] || error "Missing $ubootPath/u-boot-sunxi-with-spl.bin"
	[ -f "$ubootPath/u-boot-sunxi-with-spl.fit.fit" ] || error "Missing $ubootPath/u-boot-sunxi-with-spl.fit.fit"

	cd "$outDir"
	"$OPENTINA_BUILD_ROOT"/scripts/pack-u-boot.sh \
		"$ubootPath/u-boot-sunxi-with-spl.bin" \
		"$ubootPath/u-boot-sunxi-with-spl.fit.fit" \
		"$sdkRoot/awbin/bin/a733/u-boot-header.bin" \
		"$sdkRoot/awbin/scripts/bootpackage.py" || error "U-Boot pack failed"
}

clean_uboot() {
	local cc
	cc=$(opentina_cross_compile) || cc=aarch64-linux-gnu-
	cd "$ubootPath"

	make CROSS_COMPILE="$cc" distclean
	rm -f "$outDir"/u-boot.fex
}

linuxPath="$sdkRoot/linux"
build_linux() {
	local cc
	cc=$(opentina_cross_compile) || error "Set OPENTINA_CROSS_COMPILE or install gcc-aarch64-linux-gnu."

	cd "$linuxPath"

	echo "$LINUX_CONFIG"
	make ARCH=arm64 CROSS_COMPILE="$cc" "$LINUX_CONFIG" || error "Linux defconfig failed"

	local kfrags=()
	local opteefrag="${LINUX_OPTEE_FRAGMENT:-$OPENTINA_BUILD_ROOT/configs/common/linux-optee.fragment}"
	[ -f "$opteefrag" ] || error "Missing kernel fragment for OP-TEE: $opteefrag"
	kfrags+=("$opteefrag")

	case "${OPENTINA_ROOTFS:-buildroot}" in
	ubuntu | debian | yocto)
		local kfrag="${LINUX_SYSTEMD_FRAGMENT:-$OPENTINA_BUILD_ROOT/configs/common/linux-systemd.fragment}"
		[ -f "$kfrag" ] || error "Missing kernel fragment for distro rootfs: $kfrag"
		kfrags+=("$kfrag")
		;;
	openwrt)
		# OpenWrt's kmods are discarded (ABI mismatch with this kernel), so
		# everything its userspace needs (nftables for firewall4, bridge for
		# netifd, ...) must be built-in.
		local owfrag="${LINUX_OPENWRT_FRAGMENT:-$OPENTINA_BUILD_ROOT/configs/common/linux-openwrt.fragment}"
		[ -f "$owfrag" ] || error "Missing kernel fragment for OpenWrt rootfs: $owfrag"
		kfrags+=("$owfrag")
		;;
	esac

	echo "Merging ${kfrags[*]} (OPENTINA_ROOTFS=${OPENTINA_ROOTFS:-buildroot})"
	./scripts/kconfig/merge_config.sh -m -r -O . .config "${kfrags[@]}" || error "merge_config.sh failed"
	make ARCH=arm64 CROSS_COMPILE="$cc" olddefconfig || error "Linux olddefconfig failed"

	make ARCH=arm64 CROSS_COMPILE="$cc" || error "Linux build failed"

	cp "$linuxPath"/arch/arm64/boot/Image.gz "$outDir"
	cp "$linuxPath"/arch/arm64/boot/dts/allwinner/"$FDT_NAME" "$outDir"

	# Install all built modules (*.ko) for rootfs
	local mod_root="$outDir/modules-root"
	local mod_staging="$OPENTINA_BUILD_ROOT/.staging-linux-modules"
	rm -rf "$mod_root" "$mod_staging"
	# Ensure modules.order exists (required by modules_install).
	if [ ! -f "$linuxPath/modules.order" ]; then
		make ARCH=arm64 CROSS_COMPILE="$cc" modules \
			|| error "Linux modules build failed"
	fi
	make ARCH=arm64 CROSS_COMPILE="$cc" modules_install \
		INSTALL_MOD_PATH="$mod_root" INSTALL_MOD_STRIP=1 \
		|| error "Linux modules_install failed"
	cp -a "$mod_root" "$mod_staging"
	echo "Linux modules staged at $mod_staging/lib/modules"
	# Stage into Buildroot TARGET_DIR when present (partial rebuild / update_rootfs).
	if [ -d "$buildrootPath/output/target" ]; then
		"$OPENTINA_BUILD_ROOT/configs/common/install-linux-modules.sh" \
			"$buildrootPath/output/target"
	fi
}

clean_linux() {
	local cc
	cc=$(opentina_cross_compile) || cc=aarch64-linux-gnu-
	cd "$linuxPath"

	make ARCH=arm64 CROSS_COMPILE="$cc" distclean
	rm -f "$outDir"/Image.gz
	rm -f "$outDir/$FDT_NAME"
	rm -rf "$outDir/modules-root"
	rm -rf "$OPENTINA_BUILD_ROOT/.staging-linux-modules"
}

_linux_modules_warn_if_missing() {
	if [ ! -d "$OPENTINA_BUILD_ROOT/.staging-linux-modules/lib/modules" ]; then
		yellow_msg "No staged Linux modules; build linux first so ${1:-rootfs} gets *.ko"
	fi
}

_fetch_powervr_firmware() {
	local fw_script="$OPENTINA_BUILD_ROOT/configs/common/install-powervr-firmware.sh"
	[ -x "$fw_script" ] || error "Missing $fw_script"
	"$fw_script" --fetch || error "PowerVR firmware fetch failed"
}

# Overlay staged *.ko and PowerVR firmware onto $outDir/rootfs.ext2
# (ubuntu / debian / yocto packed ext4).
_install_linux_modules_into_out_rootfs() {
	local img="${1:-$outDir/rootfs.ext2}"
	_fetch_powervr_firmware
	"$OPENTINA_BUILD_ROOT/configs/common/install-linux-modules-into-image.sh" "$img" \
		|| error "Failed to install Linux modules/firmware into $img"
}

# Buildroot rootfs (br2 component — not the same as OPENTINA_ROOTFS=buildroot CLI token).
buildrootPath="$sdkRoot/buildroot"
build_br2() {
	[ -n "${BUILDROOT_DEFCONFIG:-}" ] || error "BUILDROOT_DEFCONFIG is not set in board config."
	local br2_cfg="$OPENTINA_BUILD_ROOT/configs/$boardConfigDir/$BUILDROOT_DEFCONFIG"
	[ -f "$br2_cfg" ] || error "Missing Buildroot defconfig: $br2_cfg"

	cd "$buildrootPath"
	# Drop a leftover BR2_EXTERNAL from older builds (configs/br2-external).
	# In-tree optee-test / optee-examples use OPENTINA_OPTEE_EXPORT; do not
	# enable BR2_TARGET_OPTEE_OS.
	make BR2_EXTERNAL= defconfig BR2_DEFCONFIG="$br2_cfg" \
		|| error "Buildroot defconfig failed"

	_linux_modules_warn_if_missing "Buildroot rootfs"

	# TAs + TA SDK from the OpenTina optee component (not BR2_TARGET_OPTEE_OS).
	export OPENTINA_OPTEE_EXPORT="${outDir%/}/optee"
	if [ ! -f "$OPENTINA_OPTEE_EXPORT/export-ta_arm64/mk/ta_dev_kit.mk" ] &&
		[ ! -f "$OPENTINA_OPTEE_EXPORT/export-ta_arm32/mk/ta_dev_kit.mk" ]; then
		error "xtest/optee-examples need the OP-TEE TA devkit; build optee first (./build.sh $boardName build optee)"
	fi
	# TA signing (sign_encrypt.py) needs distro python3-cryptography, not conda.
	if ! /usr/bin/python3 -c "import cryptography" >/dev/null 2>&1; then
		error "Missing python3 cryptography module. Install: sudo apt install python3-cryptography"
	fi
	if ! compgen -G "$OPENTINA_OPTEE_EXPORT/export-ta_*/ta/*.ta" >/dev/null 2>&1 &&
		! compgen -G "$OPENTINA_OPTEE_EXPORT/ta/*/*.ta" >/dev/null 2>&1; then
		yellow_msg "No in-tree OP-TEE TAs under $OPENTINA_OPTEE_EXPORT"
	fi

	# PowerVR firmware for request_firmware() → /lib/firmware/powervr/.
	# Fetch into dl/firmware before make; br2-post-build.sh installs it.
	_fetch_powervr_firmware

	make BR2_EXTERNAL= || error "Buildroot make failed"

	local img="$buildrootPath/output/images/rootfs.ext2"
	[ -f "$img" ] || error "Expected $img after Buildroot build (check BR2_TARGET_ROOTFS_EXT2)."
	cp -f "$img" "$outDir/rootfs.ext2"
}

clean_br2() {
	cd "$buildrootPath"
	if [ -f .config ]; then
		make BR2_EXTERNAL= clean
	fi
	rm -f "$outDir/rootfs.ext2"
}

# Pick the OEM dir forwarded to the buildx wrapper, then export
# OPENTINA_OEM_DIR (or unset it). Order:
#   1. caller-provided OPENTINA_OEM_DIR env var (verbatim, must exist)
#   2. per-board configs/<board>/oem/ (if present)
#   3. nothing → unset → buildx emits an empty .oem-staging/ (no-op)
_resolve_oem_dir() {
	local board_oem
	if [ -n "${OPENTINA_OEM_DIR:-}" ]; then
		[ -d "$OPENTINA_OEM_DIR" ] || error "OPENTINA_OEM_DIR=$OPENTINA_OEM_DIR is not a directory"
		echo "OEM: using \$OPENTINA_OEM_DIR=$OPENTINA_OEM_DIR"
		export OPENTINA_OEM_DIR
		return 0
	fi
	board_oem="$OPENTINA_BUILD_ROOT/configs/$boardConfigDir/oem"
	if [ -d "$board_oem" ]; then
		export OPENTINA_OEM_DIR="$board_oem"
		echo "OEM: using $board_oem"
		return 0
	fi
	unset OPENTINA_OEM_DIR
}

# OEM injection is only wired through the buildx Dockerfile.rootfs stage. The
# legacy debootstrap/native paths don't honour OPENTINA_OEM_DIR, so if it's set
# we refuse to fall through — silently dropping customer assets is worse than
# erroring early.
_require_buildx_for_oem() {
	[ -z "${OPENTINA_OEM_DIR:-}" ] && return 0
	error "OEM injection (OPENTINA_OEM_DIR=$OPENTINA_OEM_DIR) requires the buildx path; the current fallback does not honour it. Install docker buildx or unset OPENTINA_OEM_DIR."
}

# Ubuntu rootfs (ubuntu component — OPENTINA_ROOTFS=ubuntu CLI token).
ubuntuPath="$sdkRoot/ubuntu"
build_ubuntu() {
	[ -d "$ubuntuPath" ] || error "Missing $ubuntuPath (run: ./build.sh init)"

	local release="${UBUNTU_RELEASE:-24.04}"
	local arch="${UBUNTU_ARCH:-arm64}"
	local profile="${OPENTINA_UBUNTU_PROFILE:-lite}"
	local desktop
	case "$profile" in
	lite) desktop=0 ;;
	desktop) desktop=1 ;;
	*) error "OPENTINA_UBUNTU_PROFILE must be lite or desktop (got: $profile)" ;;
	esac

	_resolve_oem_dir
	_linux_modules_warn_if_missing "Ubuntu rootfs"

	cd "$ubuntuPath"

	# Same preference order as build_debian: buildx -> classic docker -> native.
	if command -v docker >/dev/null 2>&1 &&
		docker buildx version >/dev/null 2>&1 &&
		[ "${OPENTINA_UBUNTU_USE_BUILDX:-1}" != "0" ] &&
		[ -z "${OPENTINA_IN_DOCKER:-}" ]; then
		DESKTOP="$desktop" MAKE_EXT4=1 ARCH="$arch" ./docker/build-rootfs-buildx.sh "$release" || error "Ubuntu $profile rootfs (buildx) failed"
	elif command -v docker >/dev/null 2>&1 &&
		[ "${OPENTINA_UBUNTU_USE_DOCKER:-1}" != "0" ] &&
		[ -z "${OPENTINA_IN_DOCKER:-}" ]; then
		[ "$profile" = lite ] || error "Ubuntu desktop profile requires the buildx path."
		_require_buildx_for_oem
		ARCH="$arch" ./docker/build-rootfs.sh "$release" || error "Ubuntu rootfs (docker) failed"
	elif [ "$(dpkg --print-architecture 2>/dev/null)" = "arm64" ] && [ "$arch" = "arm64" ]; then
		[ "$profile" = lite ] || error "Ubuntu desktop profile requires the buildx path."
		_require_buildx_for_oem
		UBUNTU_RELEASE="$release" ./mk-base-ubuntu.sh "$arch" || error "mk-base-ubuntu.sh failed"
		./mk-ubuntu-rootfs.sh "$arch" || error "mk-ubuntu-rootfs.sh failed"
	else
		error "Ubuntu rootfs on $(uname -m) needs Docker on the host (sources/ubuntu/docker/build-rootfs-buildx.sh or build-rootfs.sh). On native arm64 without Docker, install binfmt-support qemu-user-static and set OPENTINA_UBUNTU_USE_DOCKER=0."
	fi

	# Select only the requested buildx profile; taking the newest arbitrary ext4
	# can silently package a desktop rootfs as lite (or vice versa).
	# Legacy path writes ubuntu-rootfs.ext4 in the repo root. Accept either.
	local img
	img=$(ls -t "$ubuntuPath"/out/ubuntu-"$release"-"$profile"-"$arch"-*.ext4 2>/dev/null | head -1)
	[ -f "$img" ] || [ "$profile" != lite ] || img="$ubuntuPath/ubuntu-rootfs.ext4"
	[ -f "$img" ] || error "Expected an Ubuntu $profile ext4 image after rootfs build."
	cp -f "$img" "$outDir/rootfs.ext2"
	_install_linux_modules_into_out_rootfs
	printf '%s\n' "$profile" > "$outDir/.ubuntu-profile"
	echo "Copied Ubuntu $profile rootfs: $img -> $outDir/rootfs.ext2"
}

clean_ubuntu() {
	[ -d "$ubuntuPath" ] || return 0
	cd "$ubuntuPath"
	if [ -x ./build.sh ]; then
		./build.sh clean
	fi
	rm -f "$outDir/rootfs.ext2"
	rm -f "$outDir/.ubuntu-profile"
}

# Debian rootfs (debian component — OPENTINA_ROOTFS=debian CLI token).
debianPath="$sdkRoot/debian"
build_debian() {
	[ -d "$debianPath" ] || error "Missing $debianPath (run: ./build.sh init)"

	local release="${DEBIAN_RELEASE:-trixie}"
	local arch="${DEBIAN_ARCH:-arm64}"
	local profile="${OPENTINA_DEBIAN_PROFILE:-lite}"
	local desktop base_flavor
	case "$profile" in
	lite) desktop=0; base_flavor=-slim ;;
	desktop) desktop=1; base_flavor= ;;
	*) error "OPENTINA_DEBIAN_PROFILE must be lite or desktop (got: $profile)" ;;
	esac

	_resolve_oem_dir
	_linux_modules_warn_if_missing "Debian rootfs"

	cd "$debianPath"

	# Prefer buildx: pure Dockerfile.rootfs + BuildKit, no debootstrap / privileged
	# / qemu binfmt setup loop. Falls back to docker/build-rootfs.sh (debootstrap),
	# then to native mk-lite-rootfs.sh on arm64 hosts.
	if command -v docker >/dev/null 2>&1 &&
		docker buildx version >/dev/null 2>&1 &&
		[ "${OPENTINA_DEBIAN_USE_BUILDX:-1}" != "0" ] &&
		[ -z "${OPENTINA_IN_DOCKER:-}" ]; then
		DESKTOP="$desktop" BASE_FLAVOR="$base_flavor" HOSTNAME="debian-$profile" SERIAL_FIX="${OPENTINA_DEBIAN_SERIAL_FIX:-0}" MAKE_EXT4=1 ARCH="$arch" ./docker/build-rootfs-buildx.sh "$release" || error "Debian $profile rootfs (buildx) failed"
	elif command -v docker >/dev/null 2>&1 &&
		[ "${OPENTINA_DEBIAN_USE_DOCKER:-1}" != "0" ] &&
		[ -z "${OPENTINA_IN_DOCKER:-}" ]; then
		[ "$profile" = lite ] || error "Debian desktop profile requires the buildx path."
		_require_buildx_for_oem
		MAKE_EXT4=1 ARCH="$arch" ./docker/build-rootfs.sh "$release" || error "Debian rootfs (docker) failed"
	elif [ "$(dpkg --print-architecture 2>/dev/null)" = "arm64" ] && [ "$arch" = "arm64" ]; then
		[ "$profile" = lite ] || error "Debian desktop profile requires the buildx path."
		_require_buildx_for_oem
		MAKE_EXT4=1 ARCH="$arch" ./mk-lite-rootfs.sh "$release" || error "mk-lite-rootfs.sh failed"
	else
		error "Debian rootfs on $(uname -m) needs Docker on the host (sources/debian/docker/build-rootfs-buildx.sh or build-rootfs.sh). On native arm64 without Docker, install debootstrap qemu-user-static and set OPENTINA_DEBIAN_USE_DOCKER=0."
	fi

	local img
	img=$(ls -t "$debianPath"/out/debian-"$release"-"$profile"-"$arch"-*.ext4 2>/dev/null | head -1)
	[ -f "$img" ] || [ "$profile" != lite ] || img=$(ls -t "$debianPath"/out/*.ext4 2>/dev/null | head -1)
	[ -f "$img" ] || error "Expected a Debian $profile ext4 image after rootfs build."
	cp -f "$img" "$outDir/rootfs.ext2"
	_install_linux_modules_into_out_rootfs
	printf '%s\n' "$profile" > "$outDir/.debian-profile"
	echo "Copied Debian $profile rootfs: $img -> $outDir/rootfs.ext2"
}

clean_debian() {
	[ -d "$debianPath" ] || return 0
	cd "$debianPath"
	if [ -x ./build.sh ]; then
		./build.sh clean-out
	fi
	rm -f "$outDir/rootfs.ext2"
}

# Yocto rootfs (yocto component — OPENTINA_ROOTFS=yocto; layer meta-opentina).
metaOpentinaPath="$sdkRoot/meta-opentina"
build_yocto() {
	[ -d "$metaOpentinaPath" ] || error "Missing $metaOpentinaPath (run: ./build.sh init)"

	if [ "$(id -u)" -eq 0 ]; then
		error "Yocto/bitbake must not run as root (see sources/meta-opentina/README.md)."
	fi

	local profile="${OPENTINA_YOCTO_PROFILE:-minimal}"
	local machine="${YOCTO_MACHINE:-${OPENTINA_YOCTO_MACHINE:-a733-aiot}}"
	export OPENTINA_YOCTO_DIR="${OPENTINA_YOCTO_DIR:-$sdkRoot/yocto}"
	export MACHINE="$machine"

	case "$profile" in
	minimal | qt | hmi) ;;
	*)
		error "OPENTINA_YOCTO_PROFILE must be minimal, qt or hmi (got: $profile)"
		;;
	esac

	cd "$metaOpentinaPath"
	[ -x ./opentina-build.sh ] || error "Missing $metaOpentinaPath/opentina-build.sh"
	[ -x ./yocto-init.sh ] || error "Missing $metaOpentinaPath/yocto-init.sh"

	if [ ! -f "${OPENTINA_YOCTO_DIR}/sources/meta-openembedded/meta-oe/conf/layer.conf" ]; then
		echo "Yocto: meta-openembedded missing, running yocto-init.sh ..."
		case "$profile" in
		qt) ./yocto-init.sh --qt || error "yocto-init.sh --qt failed" ;;
		*) ./yocto-init.sh || error "yocto-init.sh failed" ;;
		esac
	fi

	_linux_modules_warn_if_missing "Yocto rootfs"

	echo "Yocto profile=$profile MACHINE=$machine OPENTINA_YOCTO_DIR=$OPENTINA_YOCTO_DIR"
	./opentina-build.sh "$profile" || error "opentina-build.sh $profile failed"

	local build_rel image_basename deploy img
	case "$profile" in
	minimal)
		build_rel="build-opentina"
		image_basename="opentina-image-minimal"
		;;
	qt)
		build_rel="build-opentina-qt"
		image_basename="opentina-image-qt"
		;;
	hmi)
		build_rel="build-opentina-hmi"
		image_basename="opentina-image-hmi"
		;;
	esac

	deploy="${OPENTINA_YOCTO_DIR}/${build_rel}/tmp/deploy/images/${machine}"
	img="${deploy}/${image_basename}-${machine}.ext4"
	if [ ! -f "$img" ]; then
		img=$(ls -t "${deploy}/${image_basename}"*.ext4 2>/dev/null | head -1)
	fi
	[ -f "$img" ] || error "Expected ext4 under ${deploy}/ (bitbake ${image_basename})"
	cp -f "$img" "$outDir/rootfs.ext2"
	echo "Copied Yocto rootfs: $img -> $outDir/rootfs.ext2"
	_install_linux_modules_into_out_rootfs
}

clean_yocto() {
	rm -f "$outDir/rootfs.ext2"
}

openwrtPath() { printf '%s' "${OPENTINA_OPENWRT_DIR:-$sdkRoot/openwrt}"; }

# True if every line a patch adds is already present in the file it targets
# (the patch is committed in a fork, possibly at a shifted position).
# Patches that add nothing fall back to a reverse-apply check.
_openwrt_patch_lines_present() {
	local tree="$1" patch="$2" file line
	if ! grep -Eq '^\+($|[^+])' "$patch"; then
		(cd "$tree" && git apply --reverse --check "$patch") >/dev/null 2>&1
		return $?
	fi
	# A non-whitespace separator preserves leading tabs in added Makefile lines.
	while IFS=$'\034' read -r file line; do
		[ -f "$tree/$file" ] || return 1
		grep -qxF -- "$line" "$tree/$file" || return 1
	done < <(awk '
		/^diff --git a\// { f=$3; sub(/^a\//, "", f); next }
		/^\+\+\+/ { next }
		/^\+/ { printf "%s\034%s\n", f, substr($0, 2) }
	' "$patch")
	return 0
}

build_openwrt() {
	local owPath
	owPath="$(openwrtPath)"
	[ -d "$owPath" ] || error "Missing OpenWrt tree: $owPath (run: ./build.sh init, or set OPENTINA_OPENWRT_DIR)"

	[ -n "${OPENWRT_CONFIG:-}" ] || error "OPENWRT_CONFIG is not set in board config (path to a .config or diffconfig fragment)."
	local ow_cfg="$OPENTINA_BUILD_ROOT/configs/$boardConfigDir/$OPENWRT_CONFIG"
	[ -f "$ow_cfg" ] || error "Missing OpenWrt config: $ow_cfg"

	local subtgt="${OPENWRT_SUBTARGET:-armv8}"
	local tgt="${OPENWRT_TARGET:-sunxi}"

	if [ ! -d "$owPath/feeds" ] || [ ! -e "$owPath/feeds.conf" ] && [ ! -e "$owPath/feeds.conf.default" ]; then
		error "OpenWrt feeds layout missing at $owPath (expected feeds.conf or feeds.conf.default)."
	fi
	if [ ! -d "$owPath/package/feeds" ] || [ -z "$(ls -A "$owPath/package/feeds" 2>/dev/null)" ]; then
		blue_msg "OpenWrt: feeds update + install (first run)"
		(cd "$owPath" && ./scripts/feeds update -a >/dev/null && ./scripts/feeds install -a >/dev/null) \
			|| error "OpenWrt feeds setup failed"
	fi

	# scripts/config/ is rewritten by every OpenWrt 'make'; reset it so the
	# patch series below applies cleanly on each iteration.
	(cd "$owPath" && git checkout -- scripts/config/) >/dev/null 2>&1 || true
	local common_patch_dir="$OPENTINA_BUILD_ROOT/configs/common/openwrt-patches"
	local board_patch_dir="$OPENTINA_BUILD_ROOT/configs/$boardConfigDir/openwrt-patches"
	local patch_dir
	local patches=()
	shopt -s nullglob
	for patch_dir in "$common_patch_dir" "$board_patch_dir"; do
		[ -d "$patch_dir" ] || continue
		patches+=("$patch_dir"/*.patch)
	done
	if [ ${#patches[@]} -gt 0 ]; then
		local files
		files=$(awk '/^diff --git a\// { p=$3; sub(/^a\//, "", p); print p }' "${patches[@]}" | sort -u)
		if [ -n "$files" ]; then
			(cd "$owPath" && printf '%s\n' "$files" | xargs git checkout --) >/dev/null 2>&1 || true
		fi
		local p
		for p in "${patches[@]}"; do
			# Skip when every added line already exists in the tree (e.g. the
			# patch is committed in a fork). A position-sensitive reverse-apply
			# check breaks once later commits append below the patched block.
			if _openwrt_patch_lines_present "$owPath" "$p"; then
				echo "OpenWrt patch: $(basename "$p") already in tree, skipping"
				continue
			fi
			echo "OpenWrt patch: applying $(basename "$p")"
			(cd "$owPath" && git apply "$p") || error "OpenWrt: failed to apply $(basename "$p")"
		done
	fi
	shopt -u nullglob

	cp -f "$ow_cfg" "$owPath/.config"
	(cd "$owPath" && make defconfig) >/dev/null || error "OpenWrt 'make defconfig' failed"

	local bin_dir="$owPath/bin/targets/$tgt/$subtgt"
	rm -f "$bin_dir"/openwrt-*-rootfs.tar.gz

	local jobs="${OPENWRT_JOBS:-$JOBS}"
	(cd "$owPath" && make -j"$jobs" V=s) || error "OpenWrt build failed"

	local rootfs_tar
	rootfs_tar=$(ls -t "$bin_dir"/openwrt-*-rootfs.tar.gz 2>/dev/null | head -1)
	[ -f "$rootfs_tar" ] || error "Expected openwrt-*-rootfs.tar.gz under $bin_dir"

	local stage
	stage="$outDir/openwrt-rootfs-stage"
	rm -rf "$stage"
	mkdir -p "$stage"

	local mb="${OPENWRT_ROOTFS_MB:-2048}"
	local mod_staging="$OPENTINA_BUILD_ROOT/.staging-linux-modules"
	local fw_script="$OPENTINA_BUILD_ROOT/configs/common/install-powervr-firmware.sh"
	local ta_script="$OPENTINA_BUILD_ROOT/configs/common/install-optee-ta.sh"
	local fw_cache="${OPENTINA_FIRMWARE_CACHE:-$OPENTINA_BUILD_ROOT/dl/firmware/powervr}"
	local optee_export="${OPENTINA_OPTEE_EXPORT:-${outDir%/}/optee}"
	rm -f "$outDir/rootfs.ext2"
	_linux_modules_warn_if_missing "OpenWrt rootfs"
	_fetch_powervr_firmware

	# Extract + mkfs.ext4 -d must run with a root identity: the tarball
	# records root-owned files, and a plain-user extraction would bake the
	# build user's uid into every inode of the image. Both steps share one
	# fakeroot session (Buildroot-style) so the faked ownership survives into
	# mkfs; the docker fallback gets real root instead. OpenWrt's own kmods
	# target a different kernel ABI (e.g. 6.12.x) and cannot load on
	# sources/linux, so they are dropped and replaced with staged OpenTina
	# modules when linux was built first. PowerVR firmware and OP-TEE TAs
	# are installed the same way as Buildroot (br2-post-build.sh).
	#
	# $1=rootfs_tar $2=stage $3=rootfs.ext2 $4=size $5=mod_staging
	# $6=fw_script $7=ta_script $8=optee_export
	local mkimg='tar -xpf "$1" -C "$2" && rm -rf "$2/lib/modules" && if [ -d "$5/lib/modules" ]; then mkdir -p "$2/lib/modules" && cp -a "$5/lib/modules/." "$2/lib/modules/" && chown -R 0:0 "$2/lib/modules"; fi && "$6" "$2" && OPENTINA_OPTEE_EXPORT="$8" bash "$7" "$2" && mkfs.ext4 -d "$2" -L rootfs -m 0 -F "$3" "$4" >/dev/null'
	echo "Packing OpenWrt rootfs: $rootfs_tar -> $outDir/rootfs.ext2 (${mb}M)"
	if command -v mkfs.ext4 >/dev/null 2>&1 && [ "$(id -u)" -eq 0 ]; then
		sh -c "$mkimg" mkimg "$rootfs_tar" "$stage" "$outDir/rootfs.ext2" "${mb}M" "$mod_staging" "$fw_script" "$ta_script" "$optee_export" \
			|| error "OpenWrt rootfs image build failed"
	elif command -v mkfs.ext4 >/dev/null 2>&1 && command -v fakeroot >/dev/null 2>&1; then
		fakeroot -- sh -c "$mkimg" mkimg "$rootfs_tar" "$stage" "$outDir/rootfs.ext2" "${mb}M" "$mod_staging" "$fw_script" "$ta_script" "$optee_export" \
			|| error "OpenWrt rootfs image build failed (fakeroot)"
	elif command -v docker >/dev/null 2>&1; then
		local img="${OPENTINA_MKE2FS_IMAGE:-opentina-buildenv:24.04}"
		local docker_mod_vol=()
		local docker_mod_copy=':'
		local docker_optee_vol=()
		local docker_optee_env=(-e OPENTINA_OPTEE_EXPORT=)
		docker image inspect "$img" >/dev/null 2>&1 \
			|| docker build -t "$img" -f "$OPENTINA_BUILD_ROOT/docker/Dockerfile" "$OPENTINA_BUILD_ROOT/docker" \
			|| error "failed to build $img"
		if [ -d "$mod_staging/lib/modules" ]; then
			docker_mod_vol=(-v "$mod_staging:/staging:ro")
			docker_mod_copy='mkdir -p /stage/lib/modules && cp -a /staging/lib/modules/. /stage/lib/modules/ && chown -R 0:0 /stage/lib/modules'
		fi
		if [ -d "$optee_export" ]; then
			docker_optee_vol=(-v "$optee_export:/optee:ro")
			docker_optee_env=(-e OPENTINA_OPTEE_EXPORT=/optee)
		fi
		docker run --rm \
			-e OPENTINA_FIRMWARE_CACHE=/fwcache \
			"${docker_optee_env[@]}" \
			-v "$rootfs_tar:/rootfs.tar.gz:ro" -v "$outDir:/out" \
			-v "$fw_script:/install-powervr-firmware.sh:ro" \
			-v "$ta_script:/install-optee-ta.sh:ro" \
			-v "$fw_cache:/fwcache:ro" \
			"${docker_mod_vol[@]}" "${docker_optee_vol[@]}" --user 0:0 "$img" \
			sh -c "mkdir -p /stage && tar -xpf /rootfs.tar.gz -C /stage && rm -rf /stage/lib/modules && ${docker_mod_copy} && /install-powervr-firmware.sh /stage && bash /install-optee-ta.sh /stage && mkfs.ext4 -d /stage -L rootfs -m 0 -F /out/rootfs.ext2 ${mb}M >/dev/null && chown $(id -u):$(id -g) /out/rootfs.ext2" \
			|| error "docker mkfs.ext4 failed for OpenWrt rootfs"
	else
		error "Need mkfs.ext4 plus root/fakeroot, or docker, to build the OpenWrt rootfs image"
	fi

	rm -rf "$stage"
}

clean_openwrt() {
	local owPath
	owPath="$(openwrtPath)"
	if [ -d "$owPath" ]; then
		(cd "$owPath" && make clean) || true
	fi
	rm -rf "$outDir/openwrt-rootfs-stage"
	rm -f "$outDir/rootfs.ext2"
}

bootDir="$outDir/root/boot"
build_bootfs() {
	requires "linux"

	mkdir -p "$bootDir"

	cp "$outDir"/Image.gz "$bootDir"/vmlinuz
	cp "$outDir/$FDT_NAME" "$bootDir"

	mkdir -p "$bootDir"/extlinux
	# Kernel command line: when U-Boot uses distroboot/extlinux, the "append" line below is
	# passed to the kernel. Keep it consistent with:
	#   - GPT root slot in partitions.cfg / EXTLINUX_ROOT (e.g. root=/dev/mmcblk0p4)
	#   - serial early console (EXTLINUX_CONSOLE); duplicate earlycon here if your SoC needs UART MMIO earlycon.
	# U-Boot CONFIG_BOOTARGS is not the sole source in this layout; align any fixed bootargs in defconfig
	# with this line to avoid conflicting root/console settings.
	local root="${EXTLINUX_ROOT:-root=/dev/mmcblk0p4 rw rootwait}"
	local cons="${EXTLINUX_CONSOLE:-console=ttyS0,115200 loglevel=9}"
	case "${OPENTINA_ROOTFS:-buildroot}" in
	debian | yocto)
		# Root on GPT p4; boot FAT is not /boot in rootfs — disable systemd auto ESP mount.
		case " ${cons} " in
		*" systemd.gpt_auto="*) ;;
		*) cons="${cons} systemd.gpt_auto=0" ;;
		esac
		;;
	esac
	cat << EOF > "$bootDir"/extlinux/extlinux.conf
default opentina

label opentina
menu title OpenTina
	kernel /vmlinuz
	fdt /$FDT_NAME
	append $root $cons
EOF
}

clean_bootfs() {
	rm -rf "$bootDir"
}

build_image() {
	requires "bootfs"
	requires "uboot"
	case "${OPENTINA_ROOTFS:-buildroot}" in
	ubuntu) requires "ubuntu" ;;
	debian) requires "debian" ;;
	yocto) requires "yocto" ;;
	openwrt) requires "openwrt" ;;
	*) requires "br2" ;;
	esac

	cd "$outDir"
	rm -rf "$outDir/tmp"
	cp "$sdkRoot/awbin/bin/a733/$boardName/boot0_sdcard.fex" boot0.fex

	# genimage on host (default) or, when missing, inside the opentina build
	# env image (auto-built from docker/Dockerfile). Keeps a fresh host that
	# only has docker + cross-gcc able to finish the chain end-to-end.
	if command -v genimage >/dev/null 2>&1; then
		genimage --inputpath . --outputpath . --config "$PARTITION_CONFIG" \
			|| error "genimage failed"
	elif command -v docker >/dev/null 2>&1 && [ -z "${OPENTINA_IN_DOCKER:-}" ]; then
		local img="${OPENTINA_GENIMAGE_IMAGE:-opentina-buildenv:24.04}"
		if ! docker image inspect "$img" >/dev/null 2>&1; then
			echo "==> building $img from $OPENTINA_BUILD_ROOT/docker/Dockerfile (one-off)"
			docker build -t "$img" -f "$OPENTINA_BUILD_ROOT/docker/Dockerfile" \
				"$OPENTINA_BUILD_ROOT/docker" || error "failed to build $img"
		fi
		echo "==> host lacks genimage; running it inside $img"
		docker run --rm \
			-v "$OPENTINA_BUILD_ROOT:$OPENTINA_BUILD_ROOT" \
			-v "$sdkRoot:$sdkRoot" \
			-w "$outDir" \
			--user "$(id -u):$(id -g)" \
			"$img" \
			genimage --inputpath . --outputpath . --config "$PARTITION_CONFIG" \
			|| error "genimage (docker fallback) failed"
	else
		error "genimage not found on host. Install genimage, or pre-build $OPENTINA_BUILD_ROOT/docker/Dockerfile -> opentina-buildenv:24.04."
	fi
}

clean_image() {
	rm -rf "$outDir/tmp"
	rm -f "$outDir"/*.img
	rm -f "$outDir"/boot0.fex
	rm -f "$outDir"/rootfs.ext2
}
