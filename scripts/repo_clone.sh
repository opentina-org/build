#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2019-2026 Allwinner Technology Co., Ltd.
# Clone or sync OpenTina trees from an XML manifest (sophpi-style workflow).
#
# Usage:
#   ./scripts/repo_clone.sh --gitclone scripts/opentina-manifest.xml
#   ./scripts/repo_clone.sh --sync scripts/opentina-manifest.xml
#
# Manifest: optional clone-depth on <manifest> (default for all projects) or
# on <project clone-depth="N"> (overrides). Omit or empty: full history clone.
#
# Environment:
#   OPENTINA_BUILD_ROOT   Root of this build repo (default: parent of scripts/)
#   OPENTINA_SOURCES_DIR  Where projects are placed (default: $OPENTINA_BUILD_ROOT/sources)
#   OPENTINA_REMOTE_FETCH If set, overrides every <remote fetch="..."> in the manifest

set -euo pipefail

usage() {
	echo "Usage: $0 --gitclone|--sync <manifest.xml>" 1>&2
	exit 1
}

[ "${1:-}" ] || usage
mode=$1
shift
[ "${1:-}" ] || usage
manifest="$(realpath "$1")"

case "$mode" in
--gitclone | --sync) ;;
*) usage ;;
esac

script_dir="$(dirname -- "$(realpath -- "$0")")"
OPENTINA_BUILD_ROOT="${OPENTINA_BUILD_ROOT:-$(dirname -- "$script_dir")}"
export OPENTINA_BUILD_ROOT
OPENTINA_SOURCES_DIR="${OPENTINA_SOURCES_DIR:-$OPENTINA_BUILD_ROOT/sources}"
export OPENTINA_SOURCES_DIR

mkdir -p "$OPENTINA_SOURCES_DIR"

# Prints records: path<TAB>url<TAB>revision<TAB>clone_depth (empty = full clone)
_manifest_records() {
	python3 - "$manifest" <<'PY'
import sys
import xml.etree.ElementTree as ET

path = sys.argv[1]
tree = ET.parse(path)
root = tree.getroot()


def parse_clone_depth(value):
	"""Return '' for full clone, or a positive decimal string for git depth."""
	if value is None:
		return ""
	t = value.strip()
	if not t:
		return ""
	low = t.lower()
	if low in ("full", "0", "no", "false"):
		return ""
	if not t.isdigit() or int(t) < 1:
		raise SystemExit(
			f"invalid clone-depth {value!r} (use positive integer, full, 0, or omit)"
		)
	return t


default_depth = parse_clone_depth(root.get("clone-depth"))
remotes = {}
for el in root.findall("remote"):
	name = el.get("name")
	fetch = el.get("fetch")
	if name and fetch:
		remotes[name] = fetch

default_rev = "main"
default_remote = None
de = root.find("default")
if de is not None:
	if de.get("revision"):
		default_rev = de.get("revision")
	if de.get("remote"):
		default_remote = de.get("remote")
if default_remote is None and len(remotes) == 1:
	default_remote = next(iter(remotes))

override = __import__("os").environ.get("OPENTINA_REMOTE_FETCH")
if override:
	for k in list(remotes.keys()):
		remotes[k] = override

def join_fetch_name(fetch: str, name: str) -> str:
	name = name.strip().strip("/")
	fetch = fetch.rstrip("/")
	if fetch.endswith(".git"):
		return fetch
	return fetch + "/" + name + ".git"

for proj in root.findall("project"):
	url = proj.get("url")
	name = proj.get("name")
	relpath = proj.get("path") or name
	rev = proj.get("revision") or default_rev
	remote_name = proj.get("remote") or default_remote
	if proj.get("clone-depth") is None:
		depth = default_depth
	else:
		depth = parse_clone_depth(proj.get("clone-depth"))
	if not relpath or not name:
		continue
	if url:
		final = url
	else:
		if not remote_name or remote_name not in remotes:
			raise SystemExit(f"project {name!r}: missing remote (have {sorted(remotes)!r})")
		final = join_fetch_name(remotes[remote_name], name)
	print(f"{relpath}\t{final}\t{rev}\t{depth}")
PY
}

blue() {
	printf "\033[34m%s\033[39m\n" "$1"
}

yellow() {
	printf "\033[33m%s\033[39m\n" "$1"
}

while IFS="$(printf '\t')" read -r relpath url revision clone_depth; do
	[ "$relpath" ] || continue
	dest="$OPENTINA_SOURCES_DIR/$relpath"
	if [ "$mode" = "--gitclone" ]; then
		if [ -d "$dest/.git" ]; then
			yellow "skip clone (exists): $relpath"
			continue
		fi
		if [ -n "$clone_depth" ]; then
			blue "clone (depth=$clone_depth) $relpath -> $dest"
		else
			blue "clone (full) $relpath -> $dest"
		fi
		mkdir -p "$(dirname -- "$dest")"
		if [ -n "$clone_depth" ]; then
			git clone --depth "$clone_depth" --branch "$revision" "$url" "$dest"
		else
			git clone --branch "$revision" "$url" "$dest"
		fi
	else
		if ! [ -d "$dest/.git" ]; then
			yellow "skip sync (not a git repo): $relpath"
			continue
		fi
		blue "sync $relpath"
		git -C "$dest" fetch --tags origin
		git -C "$dest" checkout "$revision"
		git -C "$dest" pull --ff-only || true
	fi
done < <(_manifest_records)

blue "Done ($mode). Sources: $OPENTINA_SOURCES_DIR"
