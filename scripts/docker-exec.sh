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

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
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
		-e "JOBS=${JOBS:-}"
		-e "TERM=${TERM:-dumb}"
	)

	if [ -n "${SSH_AUTH_SOCK:-}" ] && [ -S "$SSH_AUTH_SOCK" ]; then
		docker_opts+=( -v "$SSH_AUTH_SOCK:$SSH_AUTH_SOCK" -e "SSH_AUTH_SOCK=$SSH_AUTH_SOCK" )
	fi
	if [ -d "${HOME}/.ssh" ]; then
		docker_opts+=( -v "${HOME}/.ssh:${HOME}/.ssh:ro" )
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
