#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2019-2026 Allwinner Technology Co., Ltd.
# Generate test OEM bundles for the build/ OEM injection path.
#
# Produces two bundles under build/tests/oem/:
#   good/    valid hello-opentina deb (no external deps) + rootfs-overlay + post.sh
#   broken/  hello-broken deb that Depends: on a nonexistent package
#
# The "good" bundle should install cleanly; the "broken" bundle should make
# `apt-get install ./*.deb` fail inside Dockerfile.rootfs (verifying we do
# NOT use `-f` / --fix-broken to silently work around missing deps).
#
# Usage: ./build-test-debs.sh   (writes to good/ and broken/ alongside)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARCH="${ARCH:-arm64}"

command -v dpkg-deb >/dev/null 2>&1 || {
    echo "dpkg-deb not found; install dpkg-dev or run inside the build-env container." >&2
    exit 1
}

mkdeb() {
    local name="$1" deps="$2" outdir="$3"
    local stage
    stage="$(mktemp -d -t opentina-oem-deb.XXXXXX)"
    trap 'rm -rf "$stage"' RETURN

    mkdir -p "$stage/DEBIAN" "$stage/usr/bin" "$stage/etc"
    {
        printf 'Package: %s\n' "$name"
        printf 'Version: 1.0\n'
        printf 'Section: misc\n'
        printf 'Priority: optional\n'
        printf 'Architecture: %s\n' "$ARCH"
        printf 'Maintainer: OpenTina OEM Test <noreply@example.com>\n'
        printf 'Description: OEM injection test package (%s)\n' "$name"
        [ -n "$deps" ] && printf 'Depends: %s\n' "$deps"
    } > "$stage/DEBIAN/control"

    cat > "$stage/usr/bin/opentina-hello" <<'BIN'
#!/bin/sh
echo "opentina-hello from OEM deb"
BIN
    chmod 0755 "$stage/usr/bin/opentina-hello"
    printf 'origin=%s\n' "$name" > "$stage/etc/opentina-hello.conf"

    mkdir -p "$outdir"
    dpkg-deb --build --root-owner-group "$stage" \
        "$outdir/${name}_1.0_${ARCH}.deb" >/dev/null
}

good="$SCRIPT_DIR/good"
broken="$SCRIPT_DIR/broken"
rm -rf "$good" "$broken"
mkdir -p "$good/packages" "$good/rootfs-overlay/etc" "$broken/packages"

# good: no external deps
mkdeb hello-opentina "" "$good/packages"
printf 'hello from oem rootfs-overlay\n' > "$good/rootfs-overlay/etc/opentina-oem.conf"
cat > "$good/post.sh" <<'POST'
#!/bin/sh
set -eu
echo "OEM post.sh sentinel ($(date -u +%FT%TZ))" > /etc/opentina-oem-post.stamp
POST
chmod 0755 "$good/post.sh"

# broken: declares a Depends: that nothing can satisfy
mkdeb hello-broken "nonexistent-opentina-foo-xyz (>= 99.0)" "$broken/packages"

echo "Generated test OEM bundles:"
echo "  good   -> $good"
ls -1 "$good/packages" "$good/rootfs-overlay/etc"
[ -x "$good/post.sh" ] && echo "  good/post.sh (exec)"
echo "  broken -> $broken"
ls -1 "$broken/packages"
