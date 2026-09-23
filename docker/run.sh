#!/usr/bin/env bash
#
# docker/run.sh — run a command (default: scripts/build.sh) inside the build
# container, with the repo mounted and the Buildroot download + ccache caches
# persisted on the host so rebuilds stay incremental across container runs.
#
# Buildroot refuses to build as root, so we run as the host uid:gid.
#
#   docker/run.sh                      # -> scripts/build.sh all
#   docker/run.sh scripts/build.sh kernel
#   docker/run.sh scripts/build.sh bluez5_utils
#   docker/run.sh bash                 # interactive shell
#
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

IMAGE="${AB_KERNEL_IMAGE:-}"
if [ -z "${IMAGE}" ]; then
	if docker image inspect autobleem-kernel-build >/dev/null 2>&1; then
		IMAGE=autobleem-kernel-build
	else
		IMAGE=autobleem-build   # base image; build.sh will use Buildroot's own host tools
	fi
fi

CACHE="${AB_KERNEL_CACHE:-${HOME}/.cache/autobleem-kernel}"
mkdir -p "${CACHE}/dl" "${CACHE}/ccache"

ARGS=("$@"); [ ${#ARGS[@]} -eq 0 ] && ARGS=(scripts/build.sh all)

# a terminal only when there is one (-it without one fails: "the input device is not a TTY" - CI)
TTY=(); [ -t 0 ] && [ -t 1 ] && TTY=(-it)
# BR_VERSION only when the caller set one: scripts/build.sh picks each variant's own (psc 2022.02.x, next
# 2024.02.x) - a forced default here overrode both with 2020.02.12, which does not build on this image
ENV_BR=(); [ -n "${BR_VERSION:-}" ] && ENV_BR=(-e "BR_VERSION=${BR_VERSION}")

exec docker run --rm "${TTY[@]}" \
	-u "$(id -u):$(id -g)" \
	-e HOME=/work \
	-e BR2_DL_DIR=/cache/dl \
	-e BR2_CCACHE_DIR=/cache/ccache \
	-e VARIANT="${VARIANT:-psc}" \
	"${ENV_BR[@]}" \
	-v "${HERE}:/work" \
	-v "${CACHE}:/cache" \
	-w /work \
	"${IMAGE}" \
	"${ARGS[@]}"
