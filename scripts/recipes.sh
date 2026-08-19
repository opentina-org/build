# SPDX-License-Identifier: MIT
# Copyright (c) 2019-2026 Allwinner Technology Co., Ltd.
atfPath="$sdkRoot/trusted-firmware-a"

build_atf() {
	local cc
	cc=$(opentina_cross_compile) || error "Set OPENTINA_CROSS_COMPILE or install gcc-aarch64-linux-gnu (see build2/scripts/build-sdcard-image.sh)."

	cd "$atfPath"

	make PLAT=sun60i_a733 CROSS_COMPILE="$cc" all || error "ATF build failed"
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

	local cc bl31
	cc=$(opentina_cross_compile) || error "Set OPENTINA_CROSS_COMPILE or install gcc-aarch64-linux-gnu."
	bl31="$sdkRoot/trusted-firmware-a/build/sun60i_a733/release/bl31.bin"
	[ -f "$bl31" ] || error "Missing BL31: $bl31 (build atf first)"

	cd "$ubootPath"

	# Match build2: same CROSS_COMPILE as TF-A/Linux; disable host-only mkeficapsule (gnutls).
	make CROSS_COMPILE="$cc" BL31="$bl31" "$UBOOT_CONFIG" || error "U-Boot defconfig failed"
	"$ubootPath/scripts/config" --file "$ubootPath/.config" --disable TOOLS_MKEFICAPSULE
	make CROSS_COMPILE="$cc" BL31="$bl31" olddefconfig >/dev/null || error "U-Boot olddefconfig failed"
	make CROSS_COMPILE="$cc" BL31="$bl31" || error "U-Boot build failed"

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

	case "${OPENTINA_ROOTFS:-buildroot}" in
	ubuntu | debian | yocto)
		local kfrag="${LINUX_SYSTEMD_FRAGMENT:-$OPENTINA_BUILD_ROOT/configs/common/linux-systemd.fragment}"
		[ -f "$kfrag" ] || error "Missing kernel fragment for distro rootfs: $kfrag"
		echo "Merging $kfrag (OPENTINA_ROOTFS=${OPENTINA_ROOTFS})"
		./scripts/kconfig/merge_config.sh -m -r -O . .config "$kfrag" || error "merge_config.sh failed"
		make ARCH=arm64 CROSS_COMPILE="$cc" olddefconfig || error "Linux olddefconfig failed"
		;;
	openwrt)
		# OpenWrt's kmods are discarded (ABI mismatch with this kernel), so
		# everything its userspace needs (nftables for firewall4, bridge for
		# netifd, ...) must be built-in.
		local owfrag="${LINUX_OPENWRT_FRAGMENT:-$OPENTINA_BUILD_ROOT/configs/common/linux-openwrt.fragment}"
		[ -f "$owfrag" ] || error "Missing kernel fragment for OpenWrt rootfs: $owfrag"
		echo "Merging $owfrag (OPENTINA_ROOTFS=openwrt)"
		./scripts/kconfig/merge_config.sh -m -r -O . .config "$owfrag" || error "merge_config.sh failed"
		make ARCH=arm64 CROSS_COMPILE="$cc" olddefconfig || error "Linux olddefconfig failed"
		;;
	esac

	make ARCH=arm64 CROSS_COMPILE="$cc" || error "Linux build failed"

	cp "$linuxPath"/arch/arm64/boot/Image.gz "$outDir"
	cp "$linuxPath"/arch/arm64/boot/dts/allwinner/"$FDT_NAME" "$outDir"
}

clean_linux() {
	local cc
	cc=$(opentina_cross_compile) || cc=aarch64-linux-gnu-
	cd "$linuxPath"

	make ARCH=arm64 CROSS_COMPILE="$cc" distclean
	rm -f "$outDir"/Image.gz
	rm -f "$outDir/$FDT_NAME"
}

# Buildroot rootfs (br2 component — not the same as OPENTINA_ROOTFS=buildroot CLI token).
buildrootPath="$sdkRoot/buildroot"
build_br2() {
	[ -n "${BUILDROOT_DEFCONFIG:-}" ] || error "BUILDROOT_DEFCONFIG is not set in board config."
	local br2_cfg="$OPENTINA_BUILD_ROOT/configs/$boardConfigDir/$BUILDROOT_DEFCONFIG"
	[ -f "$br2_cfg" ] || error "Missing Buildroot defconfig: $br2_cfg"

	cd "$buildrootPath"
	make defconfig BR2_DEFCONFIG="$br2_cfg" || error "Buildroot defconfig failed"
	make || error "Buildroot make failed"

	local img="$buildrootPath/output/images/rootfs.ext2"
	[ -f "$img" ] || error "Expected $img after Buildroot build (check BR2_TARGET_ROOTFS_EXT2)."
	cp -f "$img" "$outDir/rootfs.ext2"
}

clean_br2() {
	cd "$buildrootPath"
	if [ -f .config ]; then
		make clean
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

	_resolve_oem_dir

	cd "$ubuntuPath"

	# Same preference order as build_debian: buildx -> classic docker -> native.
	if command -v docker >/dev/null 2>&1 &&
		docker buildx version >/dev/null 2>&1 &&
		[ "${OPENTINA_UBUNTU_USE_BUILDX:-1}" != "0" ] &&
		[ -z "${OPENTINA_IN_DOCKER:-}" ]; then
		MAKE_EXT4=1 ARCH="$arch" ./docker/build-rootfs-buildx.sh "$release" || error "Ubuntu rootfs (buildx) failed"
	elif command -v docker >/dev/null 2>&1 &&
		[ "${OPENTINA_UBUNTU_USE_DOCKER:-1}" != "0" ] &&
		[ -z "${OPENTINA_IN_DOCKER:-}" ]; then
		_require_buildx_for_oem
		ARCH="$arch" ./docker/build-rootfs.sh "$release" || error "Ubuntu rootfs (docker) failed"
	elif [ "$(dpkg --print-architecture 2>/dev/null)" = "arm64" ] && [ "$arch" = "arm64" ]; then
		_require_buildx_for_oem
		UBUNTU_RELEASE="$release" ./mk-base-ubuntu.sh "$arch" || error "mk-base-ubuntu.sh failed"
		./mk-ubuntu-rootfs.sh "$arch" || error "mk-ubuntu-rootfs.sh failed"
	else
		error "Ubuntu rootfs on $(uname -m) needs Docker on the host (sources/ubuntu/docker/build-rootfs-buildx.sh or build-rootfs.sh). On native arm64 without Docker, install binfmt-support qemu-user-static and set OPENTINA_UBUNTU_USE_DOCKER=0."
	fi

	# buildx wrapper writes ubuntu-<release>-lite-<arch>-<date>.ext4 to out/.
	# Legacy path writes ubuntu-rootfs.ext4 in the repo root. Accept either.
	local img
	img=$(ls -t "$ubuntuPath"/out/*.ext4 2>/dev/null | head -1)
	[ -f "$img" ] || img="$ubuntuPath/ubuntu-rootfs.ext4"
	[ -f "$img" ] || error "Expected $ubuntuPath/out/*.ext4 (buildx) or $ubuntuPath/ubuntu-rootfs.ext4 (legacy) after Ubuntu rootfs build."
	cp -f "$img" "$outDir/rootfs.ext2"
}

clean_ubuntu() {
	[ -d "$ubuntuPath" ] || return 0
	cd "$ubuntuPath"
	if [ -x ./build.sh ]; then
		./build.sh clean
	fi
	rm -f "$outDir/rootfs.ext2"
}

# Debian rootfs (debian component — OPENTINA_ROOTFS=debian CLI token).
debianPath="$sdkRoot/debian"
build_debian() {
	[ -d "$debianPath" ] || error "Missing $debianPath (run: ./build.sh init)"

	local release="${DEBIAN_RELEASE:-trixie}"
	local arch="${DEBIAN_ARCH:-arm64}"

	_resolve_oem_dir

	cd "$debianPath"

	# Prefer buildx: pure Dockerfile.rootfs + BuildKit, no debootstrap / privileged
	# / qemu binfmt setup loop. Falls back to docker/build-rootfs.sh (debootstrap),
	# then to native mk-lite-rootfs.sh on arm64 hosts.
	if command -v docker >/dev/null 2>&1 &&
		docker buildx version >/dev/null 2>&1 &&
		[ "${OPENTINA_DEBIAN_USE_BUILDX:-1}" != "0" ] &&
		[ -z "${OPENTINA_IN_DOCKER:-}" ]; then
		MAKE_EXT4=1 ARCH="$arch" ./docker/build-rootfs-buildx.sh "$release" || error "Debian rootfs (buildx) failed"
	elif command -v docker >/dev/null 2>&1 &&
		[ "${OPENTINA_DEBIAN_USE_DOCKER:-1}" != "0" ] &&
		[ -z "${OPENTINA_IN_DOCKER:-}" ]; then
		_require_buildx_for_oem
		MAKE_EXT4=1 ARCH="$arch" ./docker/build-rootfs.sh "$release" || error "Debian rootfs (docker) failed"
	elif [ "$(dpkg --print-architecture 2>/dev/null)" = "arm64" ] && [ "$arch" = "arm64" ]; then
		_require_buildx_for_oem
		MAKE_EXT4=1 ARCH="$arch" ./mk-lite-rootfs.sh "$release" || error "mk-lite-rootfs.sh failed"
	else
		error "Debian rootfs on $(uname -m) needs Docker on the host (sources/debian/docker/build-rootfs-buildx.sh or build-rootfs.sh). On native arm64 without Docker, install debootstrap qemu-user-static and set OPENTINA_DEBIAN_USE_DOCKER=0."
	fi

	local img
	img=$(ls -t "$debianPath"/out/*.ext4 2>/dev/null | head -1)
	[ -f "$img" ] || error "Expected $debianPath/out/*.ext4 after Debian build (MAKE_EXT4=1)."
	cp -f "$img" "$outDir/rootfs.ext2"
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
	while IFS=$'\t' read -r file line; do
		[ -f "$tree/$file" ] || return 1
		grep -qxF -- "$line" "$tree/$file" || return 1
	done < <(awk '
		/^diff --git a\// { f=$3; sub(/^a\//, "", f); next }
		/^\+\+\+/ { next }
		/^\+/ { print f "\t" substr($0, 2) }
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

	local subtgt="${OPENWRT_SUBTARGET:-cortexa53}"
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
	local patch_dir="$OPENTINA_BUILD_ROOT/configs/$boardConfigDir/openwrt-patches"
	if [ -d "$patch_dir" ]; then
		shopt -s nullglob
		local patches=("$patch_dir"/*.patch)
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
	fi

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
	rm -f "$outDir/rootfs.ext2"

	# Drop lib/modules: OpenWrt's kmods are ABI-bound to its own kernel and
	# can't load on build/sources/linux (we put needed CONFIGs as =y via
	# linux-openwrt.fragment). Extract + mkfs share a fakeroot/docker root
	# identity so tarball ownership reaches the ext4 inodes.
	local mkimg='tar -xpf "$1" -C "$2" && rm -rf "$2/lib/modules" && mkfs.ext4 -d "$2" -L rootfs -m 0 -F "$3" "$4" >/dev/null'
	echo "Packing OpenWrt rootfs: $rootfs_tar -> $outDir/rootfs.ext2 (${mb}M)"
	if command -v mkfs.ext4 >/dev/null 2>&1 && [ "$(id -u)" -eq 0 ]; then
		sh -c "$mkimg" mkimg "$rootfs_tar" "$stage" "$outDir/rootfs.ext2" "${mb}M" \
			|| error "OpenWrt rootfs image build failed"
	elif command -v mkfs.ext4 >/dev/null 2>&1 && command -v fakeroot >/dev/null 2>&1; then
		fakeroot -- sh -c "$mkimg" mkimg "$rootfs_tar" "$stage" "$outDir/rootfs.ext2" "${mb}M" \
			|| error "OpenWrt rootfs image build failed (fakeroot)"
	elif command -v docker >/dev/null 2>&1; then
		local img="${OPENTINA_MKE2FS_IMAGE:-opentina-buildenv:24.04}"
		docker image inspect "$img" >/dev/null 2>&1 \
			|| docker build -t "$img" -f "$OPENTINA_BUILD_ROOT/docker/Dockerfile" "$OPENTINA_BUILD_ROOT/docker" \
			|| error "failed to build $img"
		docker run --rm \
			-v "$rootfs_tar:/rootfs.tar.gz:ro" -v "$outDir:/out" --user 0:0 "$img" \
			sh -c "mkdir -p /stage && tar -xpf /rootfs.tar.gz -C /stage && rm -rf /stage/lib/modules && mkfs.ext4 -d /stage -L rootfs -m 0 -F /out/rootfs.ext2 ${mb}M >/dev/null && chown $(id -u):$(id -g) /out/rootfs.ext2" \
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
