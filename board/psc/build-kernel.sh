#!/usr/bin/env bash
#
# build-kernel.sh — build the 4.4 kernel with the console's gcc-6 toolchain,
# DECOUPLED from Buildroot's (gcc-10) userland toolchain.
#
# Why: the MT8167 4.4 fork has __asmeq() register-pair inline-asm asserts that
# gcc >= 9/10 break (register allocation differs), and needs -fno-common /
# -Wattributes workarounds. gcc-6 (the era it was validated against) builds it
# clean. Buildroot's newer gcc still builds the modern userland; only the kernel
# needs the old compiler — same split the original AutoBleem pipeline used.
#
# Produces, in the stage dir:
#   <stage>/Image                     uncompressed kernel (post-image -> boot.img)
#   <stage>/rootfs/lib/modules/<ver>  stripped modules (post-build -> abrootfs.tgz)
#
# Usage: build-kernel.sh <kernel-src> <config-file> <stage-dir> [fragment ...]
#
set -euo pipefail

KSRC="$1"; CONFIG="$2"; STAGE="$3"; shift 3
FRAGMENTS=("$@")

CROSS="${AB_KERNEL_CROSS:-/opt/psc/bin/armv8-sony-linux-gnueabihf-}"
JOBS="$(nproc 2>/dev/null || echo 4)"
KBUILD="${STAGE}/build"
MODROOT="${STAGE}/rootfs"

command -v "${CROSS}gcc" >/dev/null 2>&1 || { echo "[kernel] ERROR: cross gcc not found: ${CROSS}gcc"; exit 1; }
echo "[kernel] $("${CROSS}gcc" --version | head -1)"
echo "[kernel] src=${KSRC}  stage=${STAGE}"

mkdir -p "${KBUILD}" "${MODROOT}"

# Seed the config once; keep the build dir for incremental kbuild afterwards.
if [ ! -f "${KBUILD}/.config" ] || [ "${CONFIG}" -nt "${KBUILD}/.config" ]; then
	cp "${CONFIG}" "${KBUILD}/.config"
	for f in "${FRAGMENTS[@]}"; do
		[ -f "$f" ] && { echo "[kernel] + fragment $(basename "$f")"; cat "$f" >> "${KBUILD}/.config"; }
	done
fi

M(){ make -C "${KSRC}" O="${KBUILD}" ARCH=arm CROSS_COMPILE="${CROSS}" "$@"; }

M olddefconfig
M -j"${JOBS}" Image modules
# install stripped modules into the stage rootfs (depmod runs here)
rm -rf "${MODROOT}/lib/modules"
M INSTALL_MOD_PATH="${MODROOT}" INSTALL_MOD_STRIP=1 modules_install

cp -f "${KBUILD}/arch/arm/boot/Image" "${STAGE}/Image"
echo "[kernel] done: Image $(stat -c%s "${STAGE}/Image") bytes, modules -> ${MODROOT}/lib/modules/$(ls "${MODROOT}/lib/modules" 2>/dev/null | head -1)"
