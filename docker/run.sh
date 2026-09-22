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

exec docker run --rm -it \
	-u "$(id -u):$(id -g)" \
	-e HOME=/work \
	-e BR2_DL_DIR=/cache/dl \
	-e BR2_CCACHE_DIR=/cache/ccache \
	-e BR_VERSION="${BR_VERSION:-2020.02.12}" \
	-v "${HERE}:/work" \
	-v "${CACHE}:/cache" \
	-w /work \
	"${IMAGE}" \
	"${ARGS[@]}"
