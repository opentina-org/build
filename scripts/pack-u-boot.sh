#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2019-2026 Allwinner Technology Co., Ltd.

usage() {
	echo "	$0 <U-Boot> <U-Boot FIT> <U-Boot header> <pack-script>"
	exit 1
}

[ "$#" = 4 ] || usage "$0" 1>&2

UBOOT="$1"
FIT="$2"
HEADER="$3"
PACK="$(realpath "$4")"

while [ "$1" ]; do
	if ! [ -f "$1" ]; then
		echo "$1 isn't a file" 1>&2
		usage 1>&2
	fi

	shift
done

tmpdir="$(mktemp -d)"

cat "$HEADER" "$UBOOT" > "$tmpdir"/u-boot-raw.bin
cp "$FIT" "$tmpdir"/fit.dtb

pushd "$tmpdir"

cat > boot_package.cfg << EOF
[package]
item=u-boot, u-boot-raw.bin
item=dtb, fit.dtb
EOF

env PAK="$tmpdir" python3 "$PACK" ./boot_package.cfg

popd
cp "$tmpdir"/boot_package.fex u-boot.fex
