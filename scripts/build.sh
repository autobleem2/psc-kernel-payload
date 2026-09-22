#!/usr/bin/env bash
#
# build.sh — incremental / selective build driver for the AutoBleem PSC payload.
#
# Runs on Linux (normally inside the build container via docker/run.sh). Manages
# a pinned Buildroot checkout and an out-of-tree output, wires this repo in as
# BR2_EXTERNAL, and builds one of two VARIANTS:
#
#   psc  (default) — faithful 4.4 baseline, Buildroot 2020.02.12, BlueZ 5.54
#                    + the archived DanTheMans sixaxis patch.  -> buildroot/  output/
#   next           — improved image, Buildroot 2024.02.x: newer BlueZ + userland,
#                    broader WiFi driver+firmware set, on the SAME GPU-safe 4.4
#                    kernel (your hand-tuned config + additive fragments).
#                    -> buildroot-next/  output-next/
#
# Pick the variant with -V/--variant or VARIANT=next. Both share the kernel
# (sources/psc-kernel) and your kernel config (board/psc/linux_autobleem_config);
# `next` layers board/psc/linux-extra-*.fragment ON TOP — never replacing it.
#
# Usage:  scripts/build.sh [-V psc|next] [-j N] <command> [args]
#
# Commands
#   setup                 Fetch/pin Buildroot, load the variant defconfig, wire kernel srcdir.
#   all                   Build the whole tree + assemble the payload (default).
#   kernel                Rebuild ONLY the kernel from sources/psc-kernel, repack boot.img.
#   <pkg>                 Rebuild ONLY that Buildroot package + reassemble (e.g. bluez5_utils).
#   reconfigure <pkg>     make <pkg>-reconfigure.
#   clean <pkg>           make <pkg>-dirclean (force from-scratch rebuild of one pkg).
#   assemble              Re-run post-image only: repack boot.img + abrootfs.tgz + payload.
#   payload               Copy output payload -> ./payload/<variant>/kernel.
#   menuconfig            Buildroot menuconfig.
#   linux-menuconfig      Kernel menuconfig (edit the shared base config).
#   savedefconfig         Regenerate the variant defconfig from current .config.
#   verify                Compare the built payload against reference/.
#   shell                 Interactive shell in the buildroot dir.
#   list-pkgs             Show which Buildroot packages this config enables.
#
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

VARIANT="${VARIANT:-psc}"
JOBS="$(nproc 2>/dev/null || echo 4)"

# ---- parse leading options -------------------------------------------------
while [ $# -gt 0 ]; do
	case "$1" in
		-V|--variant) VARIANT="$2"; shift 2;;
		-j) JOBS="$2"; shift 2;;
		*) break;;
	esac
done

case "${VARIANT}" in
	psc)  BR_VERSION="${BR_VERSION:-2020.02.12}"; DEFCONFIG_NAME="psc_defconfig";      SUFFIX="";;
	next) BR_VERSION="${BR_VERSION:-2024.02.x}";  DEFCONFIG_NAME="psc_next_defconfig"; SUFFIX="-next";;
	*) echo "unknown variant '${VARIANT}' (use psc|next)"; exit 2;;
esac

BR_DIR="${HERE}/buildroot${SUFFIX}"
O="${HERE}/output${SUFFIX}"
DEFCONFIG="${HERE}/configs/${DEFCONFIG_NAME}"

log(){ printf '\033[1;36m[build:%s]\033[0m %s\n' "${VARIANT}" "$*"; }
die(){ printf '\033[1;31m[build:%s] ERROR:\033[0m %s\n' "${VARIANT}" "$*" >&2; exit 1; }

brmake(){ make -C "${BR_DIR}" O="${O}" BR2_EXTERNAL="${HERE}" -j"${JOBS}" "$@"; }

fetch_buildroot(){
	if [ -f "${BR_DIR}/Makefile" ]; then log "Buildroot present in ${BR_DIR##*/}"; return; fi
	log "Fetching Buildroot ${BR_VERSION}"
	git clone --depth 1 --branch "${BR_VERSION}" \
		https://github.com/buildroot/buildroot.git "${BR_DIR}" \
		|| die "git clone of Buildroot ${BR_VERSION} failed"
}

wire_kernel_srcdir(){
	local ks="${HERE}/sources/psc-kernel"
	if [ -f "${ks}/Makefile" ]; then
		log "Kernel source override -> ${ks}"
		printf 'LINUX_OVERRIDE_SRCDIR = %s\n' "${ks}" > "${BR_DIR}/local.mk"
	else
		log "WARNING: sources/psc-kernel not checked out — Buildroot will try to fetch it."
		rm -f "${BR_DIR}/local.mk"
	fi
}

ensure_setup(){ [ -f "${O}/.config" ] || cmd_setup; }

cmd_setup(){ fetch_buildroot; wire_kernel_srcdir; log "Loading ${DEFCONFIG_NAME}"; brmake "${DEFCONFIG_NAME}"; log "Setup complete. Next: scripts/build.sh -V ${VARIANT} all"; }
cmd_all(){ ensure_setup; wire_kernel_srcdir; brmake; log "Build + payload done -> ${O}/images/psc-payload/kernel"; }
cmd_kernel(){ ensure_setup; wire_kernel_srcdir; brmake linux-rebuild; brmake target-post-image; log "Kernel rebuilt + payload repacked"; }
cmd_pkg(){ ensure_setup; brmake "${1}-rebuild"; brmake target-post-image; log "${1} rebuilt + payload repacked"; }
cmd_assemble(){ ensure_setup; brmake target-post-image; log "Payload reassembled"; }
cmd_payload(){
	local src="${O}/images/psc-payload/kernel"
	[ -d "${src}" ] || die "no payload built yet (run: scripts/build.sh -V ${VARIANT} all)"
	rm -rf "${HERE}/payload/${VARIANT}/kernel"; mkdir -p "${HERE}/payload/${VARIANT}/kernel"
	cp -a "${src}/." "${HERE}/payload/${VARIANT}/kernel/"
	log "Payload copied -> payload/${VARIANT}/kernel"; ls -la "${HERE}/payload/${VARIANT}/kernel"
}

case "${1:-all}" in
	setup)            cmd_setup;;
	all|"")           cmd_all;;
	kernel)           cmd_kernel;;
	assemble)         cmd_assemble;;
	payload)          cmd_payload;;
	verify)           O="${O}" "${HERE}/scripts/verify.sh" "${O}/images/psc-payload/kernel";;
	reconfigure)      ensure_setup; brmake "${2:?pkg}-reconfigure"; brmake target-post-image;;
	clean)            ensure_setup; brmake "${2:?pkg}-dirclean";;
	menuconfig)       ensure_setup; brmake menuconfig;;
	linux-menuconfig) ensure_setup; wire_kernel_srcdir; brmake linux-menuconfig;;
	savedefconfig)    ensure_setup; brmake savedefconfig BR2_DEFCONFIG="${DEFCONFIG}"; log "Updated ${DEFCONFIG}";;
	shell)            ensure_setup; cd "${BR_DIR}"; exec "${SHELL:-/bin/bash}";;
	list-pkgs)        ensure_setup; grep -E '^BR2_PACKAGE_[A-Z0-9_]+=y' "${O}/.config";;
	*)                cmd_pkg "$1";;
esac
