#!/usr/bin/env bash
#
# build.sh — incremental / selective build driver for the AutoBleem PSC payload.
#
# Runs on Linux (normally inside the build container via docker/run.sh). Manages
# a pinned Buildroot checkout in ./buildroot, an out-of-tree output in ./output,
# and wires this repo in as BR2_EXTERNAL. Everything Buildroot builds is cached
# per package, so re-runs are incremental and you can rebuild ONE component.
#
# Usage:  scripts/build.sh [-j N] <command> [args]
#
# Commands
#   setup                 Fetch/pin Buildroot, load psc_defconfig, wire kernel srcdir.
#   all                   Build the whole tree + assemble the payload (default).
#   kernel                Rebuild ONLY the kernel from sources/psc-kernel, repack boot.img.
#                           (make linux-rebuild + assemble)  <-- fast kernel loop
#   <pkg>                 Rebuild ONLY that Buildroot package + reassemble.
#                           e.g.  bluez5_utils   dropbear   wpa_supplicant   iw
#   reconfigure <pkg>     make <pkg>-reconfigure (re-run its ./configure, then rebuild).
#   clean <pkg>           make <pkg>-dirclean (force a from-scratch rebuild of one pkg).
#   assemble              Re-run post-image only: repack boot.img + abrootfs.tgz + payload.
#   payload               Copy output payload -> ./payload/kernel (to commit / flash).
#   menuconfig            Buildroot menuconfig.
#   linux-menuconfig      Kernel menuconfig (writes back to board/psc/linux_autobleem_config).
#   savedefconfig         Regenerate configs/psc_defconfig from current .config.
#   verify                Compare the built payload against reference/ (md5s, manifest).
#   shell                 Interactive shell in the buildroot dir with the env set.
#   list-pkgs             Show which Buildroot packages this config enables.
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BR_VERSION="${BR_VERSION:-2020.02.12}"
BR_DIR="${HERE}/buildroot"
O="${HERE}/output"
JOBS="$(nproc 2>/dev/null || echo 4)"
DEFCONFIG="${HERE}/configs/psc_defconfig"

log(){ printf '\033[1;36m[build]\033[0m %s\n' "$*"; }
die(){ printf '\033[1;31m[build] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# make wrapper: always out-of-tree with this repo as BR2_EXTERNAL
brmake(){ make -C "${BR_DIR}" O="${O}" BR2_EXTERNAL="${HERE}" -j"${JOBS}" "$@"; }

fetch_buildroot(){
	if [ -d "${BR_DIR}/.git" ] || [ -f "${BR_DIR}/Makefile" ]; then
		log "Buildroot already present in ${BR_DIR}"; return
	fi
	log "Fetching Buildroot ${BR_VERSION}"
	if command -v git >/dev/null; then
		git clone --depth 1 --branch "${BR_VERSION}" \
			https://github.com/buildroot/buildroot.git "${BR_DIR}" \
			|| die "git clone of Buildroot ${BR_VERSION} failed"
	else
		mkdir -p "${BR_DIR}"
		wget -qO- "https://buildroot.org/downloads/buildroot-${BR_VERSION}.tar.gz" \
			| tar xz --strip-components=1 -C "${BR_DIR}" || die "Buildroot download failed"
	fi
}

wire_kernel_srcdir(){
	# Use the local psc-kernel checkout (submodule) instead of letting Buildroot
	# fetch the private repo — and it makes `make linux-rebuild` recompile from
	# the working tree instantly.
	local ks="${HERE}/sources/psc-kernel"
	if [ -d "${ks}/.git" ] || [ -f "${ks}/Makefile" ]; then
		log "Kernel source override -> ${ks}"
		printf 'LINUX_OVERRIDE_SRCDIR = %s\n' "${ks}" > "${BR_DIR}/local.mk"
	else
		log "WARNING: sources/psc-kernel not checked out (git submodule update --init)."
		log "         Buildroot will try to fetch autobleem/psc-kernel over git instead."
		rm -f "${BR_DIR}/local.mk"
	fi
}

ensure_setup(){
	[ -f "${O}/.config" ] || cmd_setup
}

cmd_setup(){
	fetch_buildroot
	wire_kernel_srcdir
	log "Loading psc_defconfig"
	brmake psc_defconfig
	log "Setup complete. Next: scripts/build.sh all"
}

cmd_all(){ ensure_setup; wire_kernel_srcdir; brmake; log "Build + payload done -> ${O}/images/psc-payload/kernel"; }

cmd_kernel(){ ensure_setup; wire_kernel_srcdir; brmake linux-rebuild; brmake target-post-image; log "Kernel rebuilt + payload repacked"; }

cmd_pkg(){ local p="$1"; ensure_setup; brmake "${p}-rebuild"; brmake target-post-image; log "${p} rebuilt + payload repacked"; }

cmd_assemble(){ ensure_setup; brmake target-post-image; log "Payload reassembled"; }

cmd_payload(){
	local src="${O}/images/psc-payload/kernel"
	[ -d "${src}" ] || die "no payload built yet (run: scripts/build.sh all)"
	rm -rf "${HERE}/payload/kernel"; mkdir -p "${HERE}/payload/kernel"
	cp -a "${src}/." "${HERE}/payload/kernel/"
	log "Payload copied -> payload/kernel"
	ls -la "${HERE}/payload/kernel"
}

cmd_verify(){ "${HERE}/scripts/verify.sh"; }

case "${1:-all}" in
	-j) JOBS="$2"; shift 2; exec "$0" "$@";;
	setup)            cmd_setup;;
	all|"")           cmd_all;;
	kernel)           cmd_kernel;;
	assemble)         cmd_assemble;;
	payload)          cmd_payload;;
	verify)           cmd_verify;;
	reconfigure)      ensure_setup; brmake "${2:?pkg}-reconfigure"; brmake target-post-image;;
	clean)            ensure_setup; brmake "${2:?pkg}-dirclean";;
	menuconfig)       ensure_setup; brmake menuconfig;;
	linux-menuconfig) ensure_setup; wire_kernel_srcdir; brmake linux-menuconfig; brmake linux-update-defconfig 2>/dev/null || true;;
	savedefconfig)    ensure_setup; brmake savedefconfig BR2_DEFCONFIG="${DEFCONFIG}"; log "Updated ${DEFCONFIG}";;
	shell)            ensure_setup; cd "${BR_DIR}"; exec "${SHELL:-/bin/bash}";;
	list-pkgs)        ensure_setup; brmake show-info 2>/dev/null | tr ',' '\n' | grep -oE '"[a-z0-9_-]+"' | sort -u | head -80 || grep -E '^BR2_PACKAGE_[A-Z0-9_]+=y' "${O}/.config";;
	*)                cmd_pkg "$1";;   # bare package name -> rebuild that package
esac
