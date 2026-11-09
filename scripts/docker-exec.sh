#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2019-2026 Allwinner Technology Co., Ltd.
# Run OpenTina inside Ubuntu 24.04 Docker, or open an interactive shell there.
# Invoked from build.sh when OPENTINA_DOCKER=1 / --docker, or for --docker-shell.
set -euo pipefail

: "${OPENTINA_BUILD_ROOT:?OPENTINA_BUILD_ROOT must be set}"

opentina_container_hostname="${OPENTINA_DOCKER_HOSTNAME:-opentina}"

IMAGE="${OPENTINA_DOCKER_IMAGE:-opentina-buildenv:24.04}"
DOCKERFILE="${OPENTINA_BUILD_ROOT}/docker/Dockerfile"
CTX_DIR="${OPENTINA_BUILD_ROOT}/docker"

if ! command -v docker >/dev/null 2>&1; then
	echo "docker: command not found. Install Docker, or run on the host without OPENTINA_DOCKER=1." >&2
	exit 127
fi

opentina_docker_image_stale() {
	if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
		return 0
	fi
	# Rebuild when docker/Dockerfile is newer than the existing image.
	local df_mtime img_epoch
	df_mtime=$(stat -c %Y "$DOCKERFILE" 2>/dev/null) || return 1
	img_epoch=$(date -u -d "$(docker image inspect -f '{{.Created}}' "$IMAGE")" +%s 2>/dev/null) || return 1
	[ "$df_mtime" -gt "$img_epoch" ]
}

if opentina_docker_image_stale; then
	echo "Building Docker image $IMAGE (Ubuntu 24.04 build env) ..."
	docker build -t "$IMAGE" -f "$DOCKERFILE" "$CTX_DIR"
fi

opentina_docker_opts() {
	docker_opts=(
		--rm
		-i
		--hostname "$opentina_container_hostname"
		-v "${OPENTINA_BUILD_ROOT}:${OPENTINA_BUILD_ROOT}"
		-w "${OPENTINA_BUILD_ROOT}"
		-e "OPENTINA_IN_DOCKER=1"
		-e "HOME=${HOME:-/root}"
		-e "OPENTINA_CROSS_COMPILE=${OPENTINA_CROSS_COMPILE:-}"
		-e "CROSS_COMPILE=${CROSS_COMPILE:-}"
		-e "OPENTINA_REMOTE_FETCH=${OPENTINA_REMOTE_FETCH:-}"
		-e "OPENTINA_OPTEE=${OPENTINA_OPTEE:-}"
		-e "OPENTINA_BR2_PROFILE=${OPENTINA_BR2_PROFILE:-}"
		-e "OPENTINA_UBUNTU_PROFILE=${OPENTINA_UBUNTU_PROFILE:-}"
		-e "OPENTINA_DEBIAN_PROFILE=${OPENTINA_DEBIAN_PROFILE:-}"
		-e "OPENTINA_YOCTO_PROFILE=${OPENTINA_YOCTO_PROFILE:-}"
		-e "OPENTINA_RESUME=${OPENTINA_RESUME:-}"
		-e "OPENTINA_FORCE_BUILD=${OPENTINA_FORCE_BUILD:-}"
		-e "JOBS=${JOBS:-}"
		-e "TERM=${TERM:-dumb}"
		# BitBake (and similar) call unshare(CLONE_NEWUSER). Docker's
		# default seccomp profile blocks that even when the host
		# kernel.apparmor_restrict_unprivileged_userns=0.
		--security-opt seccomp=unconfined
	)

	if [ -n "${SSH_AUTH_SOCK:-}" ] && [ -S "$SSH_AUTH_SOCK" ]; then
		docker_opts+=( -v "$SSH_AUTH_SOCK:$SSH_AUTH_SOCK" -e "SSH_AUTH_SOCK=$SSH_AUTH_SOCK" )
	fi
	if [ -d "${HOME}/.ssh" ]; then
		docker_opts+=( -v "${HOME}/.ssh:${HOME}/.ssh:ro" )
	fi
	# HOME is the host path, but that directory is not in the image and
	# /home is root-owned. ccache writes $HOME/.cache/ccache and otherwise
	# exits "Permission denied" before the compiler runs.
	local cache_home="${HOME:-/root}/.cache"
	mkdir -p "$cache_home"
	docker_opts+=( -v "${cache_home}:${cache_home}" )

	# Ubuntu/Debian rootfs use host Docker/buildx (same-path repo mount so
	# buildx -o dest=... and docker -v paths resolve on the daemon).
	if [ -S /var/run/docker.sock ]; then
		docker_opts+=( -v /var/run/docker.sock:/var/run/docker.sock )
		local sock_gid docker_bin plugindir
		sock_gid=$(stat -c '%g' /var/run/docker.sock 2>/dev/null) || sock_gid=
		[ -n "$sock_gid" ] && docker_opts+=( --group-add "$sock_gid" )
		docker_bin=$(command -v docker) || docker_bin=
		case "$docker_bin" in
		'' | /snap/*) ;;
		*)
			[ -f "$docker_bin" ] && docker_opts+=( -v "$docker_bin:/usr/bin/docker:ro" )
			;;
		esac
		for plugindir in /usr/libexec/docker/cli-plugins /usr/lib/docker/cli-plugins; do
			[ -d "$plugindir" ] && docker_opts+=( -v "$plugindir:$plugindir:ro" )
		done
		if [ -n "${HOME:-}" ] && [ -d "${HOME}/.docker" ]; then
			docker_opts+=( -v "${HOME}/.docker:${HOME}/.docker" )
		fi
	fi

	if docker run --help 2>&1 | grep -q -- '--user'; then
		docker_opts+=( --user "$(id -u):$(id -g)" )
	fi

	if [ -t 0 ] && [ -t 1 ]; then
		docker_opts+=( -t )
	fi
}

if [ "${1:-}" = --shell ]; then
	shift
	opentina_docker_opts
	exec docker run "${docker_opts[@]}" "$IMAGE" bash -il
fi

opentina_docker_opts
exec docker run "${docker_opts[@]}" "$IMAGE" \
	bash "${OPENTINA_BUILD_ROOT}/build.sh" "$@"
