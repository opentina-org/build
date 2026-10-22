#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Print git revisions for this build repo and the cloned source trees.
#
# Columns (TAB-separated): path, commit, abbrev, ref, url
# Usage: ./scripts/source-revs.sh
#
# Environment:
#   OPENTINA_BUILD_ROOT   Root of this build repo (default: parent of scripts/)
#   OPENTINA_SOURCES_DIR  Cloned projects (default: $OPENTINA_BUILD_ROOT/sources)
#   OPENTINA_MANIFEST     Manifest used to order projects (default: scripts/opentina-manifest.xml)

set -euo pipefail

script_dir="$(dirname -- "$(realpath -- "$0")")"
OPENTINA_BUILD_ROOT="${OPENTINA_BUILD_ROOT:-$(dirname -- "$script_dir")}"
OPENTINA_SOURCES_DIR="${OPENTINA_SOURCES_DIR:-$OPENTINA_BUILD_ROOT/sources}"
manifest="${OPENTINA_MANIFEST:-$OPENTINA_BUILD_ROOT/scripts/opentina-manifest.xml}"

emit_repo() {
	local path_label="$1"
	local dir="$2"
	[ -e "$dir/.git" ] || return 0
	local commit abbrev ref url
	commit="$(git -C "$dir" rev-parse HEAD)"
	abbrev="$(git -C "$dir" rev-parse --short=12 HEAD)"
	if ref="$(git -C "$dir" symbolic-ref -q --short HEAD)"; then
		:
	elif ref="$(git -C "$dir" describe --tags --exact-match 2>/dev/null)"; then
		:
	else
		ref=detached
	fi
	url="$(git -C "$dir" remote get-url origin 2>/dev/null || true)"
	# CI clones through an insteadOf rewrite that embeds the token; never record it.
	url="$(printf '%s' "$url" | sed -E 's#^([a-z+]+://)[^/@]*:[^/@]*@#\1#')"
	printf '%s\t%s\t%s\t%s\t%s\n' "$path_label" "$commit" "$abbrev" "$ref" "$url"
}

echo "# path	commit	abbrev	ref	url"
emit_repo "build" "$OPENTINA_BUILD_ROOT"

if [ -f "$manifest" ]; then
	while IFS= read -r relpath; do
		[ "$relpath" ] || continue
		emit_repo "$relpath" "$OPENTINA_SOURCES_DIR/$relpath"
	done < <(
		python3 - "$manifest" <<'PY'
import sys
import xml.etree.ElementTree as ET

root = ET.parse(sys.argv[1]).getroot()
# Firmware / rootfs trees only; docs is not part of the image.
skip = {"docs"}
for proj in root.findall("project"):
    name = proj.get("name")
    relpath = proj.get("path") or name
    if not relpath or relpath in skip or name in skip:
        continue
    print(relpath)
PY
	)
fi
