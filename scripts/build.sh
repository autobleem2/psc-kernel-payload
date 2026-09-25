#!/usr/bin/env bash
#
# build.sh — incremental / selective build driver for the AutoBleem PSC payload.
#
# Two build systems, on purpose:
#   * the KERNEL (+ modules) is built by board/psc/build-kernel.sh with the
#     console gcc-6 toolchain (the 4.4 fork's __asmeq asserts break on gcc>=9);
#   * the USERLAND is built by Buildroot with its own newer gcc, then Buildroot
#     folds the staged kernel modules into the rootfs (post-build) and wraps the
#     kernel Image into boot.img (post-image).
#
# Two VARIANTS (see -V): `psc` (baseline) and `next` (newer BlueZ/userland +
# extra WiFi drivers). Separate Buildroot checkouts and outputs.
#
# Usage:  scripts/build.sh [-V psc|next] [-j N] <command> [args]
#
# Commands
#   setup                 Fetch/pin Buildroot and load the variant defconfig.
#   all                   Build kernel + userland + assemble the payload (default).
#   kernel                Rebuild ONLY the kernel (incremental) + repack the payload.
#   kconfig               menuconfig the kernel; writes board/psc/linux_autobleem_config.
#   kclean                Wipe the kernel build dir (force a full kernel rebuild).
#   <pkg>                 Rebuild ONLY that Buildroot userland package + reassemble.
#   clean <pkg>           make <pkg>-dirclean.
#   assemble              Re-run post-build + post-image only (repack payload).
#   payload               Copy the payload -> ./payload/<variant>/kernel.
#   menuconfig            Buildroot (userland) menuconfig.
#   savedefconfig         Regenerate the variant defconfig.
#   verify                Compare the built payload against reference/.
#   shell                 Interactive shell in the buildroot dir.
#
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

VARIANT="${VARIANT:-psc}"
JOBS="$(nproc 2>/dev/null || echo 4)"
while [ $# -gt 0 ]; do
	case "$1" in
		-V|--variant) VARIANT="$2"; shift 2;;
		-j) JOBS="$2"; shift 2;;
		*) break;;
	esac
done

case "${VARIANT}" in
	psc)  BR_VERSION="${BR_VERSION:-2022.02.x}"; DEFCONFIG_NAME="psc_defconfig";      SUFFIX="";;
	next) BR_VERSION="${BR_VERSION:-2024.02.x}";  DEFCONFIG_NAME="psc_next_defconfig"; SUFFIX="-next";;
	*) echo "unknown variant '${VARIANT}' (use psc|next)"; exit 2;;
esac

BR_DIR="${HERE}/buildroot${SUFFIX}"
O="${HERE}/output${SUFFIX}"
DEFCONFIG="${HERE}/configs/${DEFCONFIG_NAME}"
KSRC="${HERE}/sources/psc-kernel"
KCONFIG="${HERE}/board/psc/linux_autobleem_config"
KSTAGE="${O}/kernel-stage"
# linux-common.fragment for both variants (pad drivers as modules, the in-tree USB WiFi drivers), next adds its own
KFRAG="${HERE}/board/psc/linux-common.fragment"
[ "${VARIANT}" = "next" ] && KFRAG="${KFRAG} ${HERE}/board/psc/linux-extra-wifi.fragment"

log(){ printf '\033[1;36m[build:%s]\033[0m %s\n' "${VARIANT}" "$*"; }
die(){ printf '\033[1;31m[build:%s] ERROR:\033[0m %s\n' "${VARIANT}" "$*" >&2; exit 1; }
brmake(){ make -C "${BR_DIR}" O="${O}" BR2_EXTERNAL="${HERE}" -j"${JOBS}" "$@"; }

fetch_buildroot(){
	[ -f "${BR_DIR}/Makefile" ] && { log "Buildroot present in ${BR_DIR##*/}"; return; }
	log "Fetching Buildroot ${BR_VERSION}"
	git clone --depth 1 --branch "${BR_VERSION}" \
		https://github.com/buildroot/buildroot.git "${BR_DIR}" || die "Buildroot clone failed"
}

build_kernel(){
	[ -f "${KSRC}/Makefile" ] || die "kernel source missing at ${KSRC} — git submodule update --init (or clone from the mirror)"
	bash "${HERE}/board/psc/build-kernel.sh" "${KSRC}" "${KCONFIG}" "${KSTAGE}" ${KFRAG}
}

ensure_setup(){ [ -f "${O}/.config" ] || cmd_setup; }
cmd_setup(){ fetch_buildroot; log "Loading ${DEFCONFIG_NAME}"; brmake "${DEFCONFIG_NAME}"; log "Setup done."; }
cmd_all(){ ensure_setup; build_kernel; brmake; log "Payload -> ${O}/images/psc-payload/kernel"; }
cmd_kernel(){ ensure_setup; build_kernel; brmake; log "Kernel rebuilt + payload repacked"; }
cmd_pkg(){ ensure_setup; brmake "${1}-rebuild"; brmake; log "${1} rebuilt + payload repacked"; }
cmd_assemble(){ ensure_setup; brmake; log "Payload reassembled"; }
cmd_kconfig(){
	build_kernel >/dev/null 2>&1 || true   # ensure the build dir + .config exist
	make -C "${KSRC}" O="${KSTAGE}/build" ARCH=arm CROSS_COMPILE="${AB_KERNEL_CROSS:-/opt/psc/bin/armv8-sony-linux-gnueabihf-}" menuconfig
	cp "${KSTAGE}/build/.config" "${KCONFIG}"; log "Wrote ${KCONFIG}"
}
cmd_payload(){
	local src="${O}/images/psc-payload/kernel"
	[ -d "${src}" ] || die "no payload built yet"
	rm -rf "${HERE}/payload/${VARIANT}/kernel"; mkdir -p "${HERE}/payload/${VARIANT}/kernel"
	cp -a "${src}/." "${HERE}/payload/${VARIANT}/kernel/"
	log "Payload -> payload/${VARIANT}/kernel"; ls -la "${HERE}/payload/${VARIANT}/kernel"
}

case "${1:-all}" in
	setup)         cmd_setup;;
	all|"")        cmd_all;;
	kernel)        cmd_kernel;;
	kconfig)       cmd_kconfig;;
	kclean)        rm -rf "${KSTAGE}/build"; log "kernel build dir wiped";;
	assemble)      cmd_assemble;;
	payload)       cmd_payload;;
	verify)        "${HERE}/scripts/verify.sh" "${O}/images/psc-payload/kernel";;
	clean)         ensure_setup; brmake "${2:?pkg}-dirclean";;
	menuconfig)    ensure_setup; brmake menuconfig;;
	savedefconfig) ensure_setup; brmake savedefconfig BR2_DEFCONFIG="${DEFCONFIG}"; log "Updated ${DEFCONFIG}";;
	shell)         ensure_setup; cd "${BR_DIR}"; exec "${SHELL:-/bin/bash}";;
	*)             cmd_pkg "$1";;
esac
