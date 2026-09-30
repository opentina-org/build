# SPDX-License-Identifier: MIT
# Generic custom-package builder.
#
# A fork under sources/ becomes a build component without touching this file:
#
#   ./build.sh <BOARD> build <repo>      builds it   (function: build_<repo>)
#   ./build.sh <BOARD> clean <repo>      removes .done and the staged .debs
#
# Layout conventions inside sources/<repo>/:
#   debian/     exists -> dpkg-buildpackage inside an arm64 container (native
#               build, same emulation the rootfs builds already use)
#   *.bb        exists -> not implemented yet; error with a clear message
#   neither     -> error: nothing this builder knows how to do
#
# Artifacts land in output/<BOARD>/custom-debs/ for the rootfs injection step
# (OPENTINA_CUSTOM_DEBS, planned; the OEM staging path is the model).
#
# Versioning rule for packages built this way: the debian/changelog version
# must carry a ~opentina suffix and a git short SHA so packages stay
# distinguishable from and reversible against distro ones, and dependencies on
# distro components must use >=, never =.

_custom_pkg_repo_path() {
	local repo="$1"
	local path="$sdkRoot/$repo"
	[ -d "$path/.git" ] || error "custom package \"$repo\": no git repo at $path (./build.sh init)"
	printf '%s\n' "$path"
}

_custom_pkg_build_deb() {
	local repo="$1" path="$2"
	local out="${outDir%/}/custom-debs"
	local image="${OPENTINA_CUSTOM_PKG_IMAGE:-debian:trixie}"

	[ -d "$path/debian" ] || error "custom package \"$repo\": no debian/ directory; nothing to build"

	# Uncommitted changes make the git short SHA in the version a lie.
	if [ -n "$(git -C "$path" status --porcelain 2>/dev/null)" ]; then
		error "custom package \"$repo\": working tree is dirty; commit first so the version SHA is meaningful"
	fi

	mkdir -p "$out"
	echo "custom-pkg: building $repo in $image (arm64)"
	docker run --rm --platform linux/arm64 \
		-v "$path":/src:ro \
		-v "$out":/out \
		-e DEBIAN_FRONTEND=noninteractive \
		-e JOBS="${JOBS:-4}" \
		"$image" bash -eu -c '
			apt-get -qq update >/dev/null
			# Packaging toolchain first: rules files may call fakeroot
			# explicitly (dpkg-buildpackage only pulls it for non-root),
			# and devscripts tools are common in custom rules.
			apt-get -y install -qq --no-install-recommends fakeroot >/dev/null
			apt-get -y build-dep /src >/dev/null 2>&1 || {
				echo "NOTE: apt-get build-dep failed; retrying with dpkg-checkbuilddeps for a precise report" >&2
				dpkg-checkbuilddeps /src/debian/control || true
				exit 1
			}
			cp -a /src /build && cd /build
			dpkg-buildpackage -us -uc -b -j"${JOBS}" 2>&1
			mv /build/../*.deb /out/
		' || error "custom package \"$repo\": build failed"
	echo "custom-pkg: $repo -> $out:"
	ls -l "$out"/*.deb | sed 's/^/  /'
}

# build_<repo> dispatcher. Bash accepts hyphens in function names, so
# build_gst-omx is reachable as long as we declare it dynamically.
_custom_pkg_dispatch() {
	local repo="$gThisComponent"
	local path
	path="$(_custom_pkg_repo_path "$repo")"

	if [ -d "$path/debian" ]; then
		_custom_pkg_build_deb "$repo" "$path"
	elif ls "$path"/*.bb >/dev/null 2>&1; then
		error "custom package \"$repo\": bitbake recipe detected but not implemented yet; put it in a layer instead"
	else
		error "custom package \"$repo\": neither debian/ nor a .bb found; nothing this builder knows how to do"
	fi
}

_custom_pkg_clean() {
	local repo="$gThisComponent"
	rm -f "${outDir%/}/.done.$repo"
	rm -f "${outDir%/}/custom-debs/${repo}"*.deb 2>/dev/null || true
	echo "custom-pkg: cleaned $repo (staged .debs removed)"
}

# Dynamically define build_<repo>/clean_<repo> for every git repo under
# sources/ that is not one of the manifest's firmware components. Runs when
# recipes.sh is sourced, before the dispatch loop.
_custom_pkg_register_all() {
	local d name
	for d in "$sdkRoot"/*/; do
		[ -d "$d/.git" ] || continue
		name="$(basename "$d")"
		case "$name" in
			trusted-firmware-a|optee_os|u-boot|linux|buildroot|ubuntu|debian|meta-opentina|openwrt|awbin|docs|yocto)
				continue
				;;
		esac
		eval "build_${name}() { gThisComponent='${name}'; _custom_pkg_dispatch; }"
		eval "clean_${name}() { gThisComponent='${name}'; _custom_pkg_clean; }"
	done
}
