#!/usr/bin/env bash
# Copy OP-TEE trusted applications into a rootfs-like tree.
# Usage: install-optee-ta.sh <DEST_ROOT>
#
# Looks for *.ta under (first match wins):
#   $OPENTINA_OPTEE_EXPORT
#   $outDir/optee
#   $OPENTINA_BUILD_ROOT/output/<board>/optee
# in both export-ta_*/ta/ and ta/<name>/.
set -euo pipefail

DEST_ROOT="${1:?usage: $0 <DEST_ROOT>}"
SCRIPT_DIR="$(cd "$(dirname -- "$0")" && pwd)"
BUILD_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

has_tas() {
	local root="$1"
	[ -d "$root" ] || return 1
	compgen -G "$root/export-ta_*/ta/*.ta" >/dev/null 2>&1 && return 0
	compgen -G "$root/ta/*/*.ta" >/dev/null 2>&1 && return 0
	return 1
}

resolve_export() {
	local d
	if [ -n "${OPENTINA_OPTEE_EXPORT:-}" ] && has_tas "$OPENTINA_OPTEE_EXPORT"; then
		printf '%s\n' "$OPENTINA_OPTEE_EXPORT"
		return 0
	fi
	if [ -n "${outDir:-}" ] && has_tas "${outDir%/}/optee"; then
		printf '%s\n' "${outDir%/}/optee"
		return 0
	fi
	for d in "$BUILD_ROOT"/output/*/optee; do
		has_tas "$d" || continue
		printf '%s\n' "$d"
		return 0
	done
	return 1
}

EXPORT=""
if ! EXPORT="$(resolve_export)"; then
	echo "install-optee-ta: no OP-TEE TAs found (build optee first); skip"
	exit 0
fi

n=0
mkdir -p "$DEST_ROOT/lib/optee_armtz" "$DEST_ROOT/data/tee"

shopt -s nullglob
for ta in "$EXPORT"/export-ta_*/ta/*.ta; do
	cp -a "$ta" "$DEST_ROOT/lib/optee_armtz/"
	n=$((n + 1))
done
if [ "$n" -eq 0 ]; then
	for ta in "$EXPORT"/ta/*/*.ta; do
		cp -a "$ta" "$DEST_ROOT/lib/optee_armtz/"
		n=$((n + 1))
	done
fi
shopt -u nullglob

if [ "$(id -u)" -eq 0 ]; then
	chown -R 0:0 "$DEST_ROOT/lib/optee_armtz" "$DEST_ROOT/data/tee"
fi

if [ "$n" -eq 0 ]; then
	echo "install-optee-ta: no *.ta under $EXPORT (build optee first)"
	exit 0
fi
echo "install-optee-ta: installed $n TA(s) from $EXPORT -> $DEST_ROOT/lib/optee_armtz"
