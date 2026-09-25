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

# Seed the config once; keep the build dir for incremental kbuild afterwards - seeded again when the base config
# or a fragment changed (a fragment edit alone used to leave the old .config in place)
reseed=0
[ -f "${KBUILD}/.config" ] || reseed=1
for f in "${CONFIG}" "${FRAGMENTS[@]}"; do [ -f "$f" ] && [ "$f" -nt "${KBUILD}/.config" ] && reseed=1; done
if [ "${reseed}" = 1 ]; then
	cp "${CONFIG}" "${KBUILD}/.config"
	for f in "${FRAGMENTS[@]}"; do
		[ -f "$f" ] && { echo "[kernel] + fragment $(basename "$f")"; cat "$f" >> "${KBUILD}/.config"; }
	done
fi

# ccache in front of the gcc-6 cross compiler when there is one: the kernel is the one part of the payload
# Buildroot's BR2_CCACHE does not cover (it is built here, outside Buildroot), and CI starts from an empty
# build dir every run. KCCACHE_DIR (docker/run.sh points it into the persisted cache) keeps it apart from
# Buildroot's own ccache. AB_KERNEL_NO_CCACHE=1 turns it off.
KCC=()
if command -v ccache >/dev/null 2>&1 && [ -z "${AB_KERNEL_NO_CCACHE:-}" ]; then
	export CCACHE_DIR="${KCCACHE_DIR:-${HOME}/.ccache-kernel}" CCACHE_MAXSIZE="${KCCACHE_MAXSIZE:-2G}"
	# hits across checkouts at other paths and kbuild's timestamp macros
	export CCACHE_BASEDIR="${KSRC}" CCACHE_SLOPPINESS="time_macros,include_file_mtime,include_file_ctime,file_macro"
	KCC=(CC="ccache ${CROSS}gcc")
	echo "[kernel] ccache: ${CCACHE_DIR} ($(ccache -s 2>/dev/null | grep -iE '^(cache size|hits)' | head -1 | tr -s ' '))"
fi
# LOCALVERSION= (set, empty): the release is 4.4.22, as the 2020 kernel's was - left unset, setlocalversion
# appends a '+' for a source tree that is not at an annotated tag, and every module built for 2020's kernel
# (the libs pack's xpad.ko) is then refused for its version magic.
M(){ make -C "${KSRC}" O="${KBUILD}" ARCH=arm CROSS_COMPILE="${CROSS}" LOCALVERSION= "${KCC[@]}" "$@"; }

# modules_install runs depmod only when it exists, and says no more than a warning when it does not - which is
# how payloads without modules.dep/modules.alias shipped (no module ever loaded on the console)
DEPMOD="$(command -v depmod || true)"
[ -n "${DEPMOD}" ] || for d in /sbin/depmod /usr/sbin/depmod; do [ -x "$d" ] && DEPMOD="$d"; done
[ -n "${DEPMOD}" ] || { echo "[kernel] ERROR: no depmod (install kmod in the build image)"; exit 1; }

# CONFIG_INITRAMFS_SOURCE is a relative path ("initramfs"); in an out-of-tree
# build (O=) the kernel resolves it against the build dir, not the source, so
# mirror the in-tree initramfs/ there (it holds the built-in /init).
if [ -d "${KSRC}/initramfs" ]; then
	rm -rf "${KBUILD}/initramfs"; cp -a "${KSRC}/initramfs" "${KBUILD}/initramfs"
fi

M olddefconfig
M -j"${JOBS}" Image modules
# install stripped modules into the stage rootfs (depmod runs here)
rm -rf "${MODROOT}/lib/modules"
M INSTALL_MOD_PATH="${MODROOT}" INSTALL_MOD_STRIP=1 DEPMOD="${DEPMOD}" modules_install
KREL="$(cat "${KBUILD}/include/config/kernel.release")"
for f in modules.dep modules.alias; do
	[ -s "${MODROOT}/lib/modules/${KREL}/${f}" ] || { echo "[kernel] ERROR: depmod wrote no ${f} for ${KREL}"; exit 1; }
done
echo "[kernel] release ${KREL}, $(wc -l < "${MODROOT}/lib/modules/${KREL}/modules.dep") modules indexed"

# Relocations 4.4's ARM module loader cannot apply (GOT-relative: what a PIE-by-default gcc makes without
# -fno-PIE, which psc-kernel's Makefile passes since 2026-09-25). A module carrying one never loads ("unknown
# relocation"), and until then 100 of 107 did - refuse the build instead.
READELF="${CROSS}readelf"
command -v "${READELF}" >/dev/null 2>&1 || READELF=readelf
bad=""
while IFS= read -r ko; do
	# grep -c, not -q: -q quits at the first match, readelf dies of SIGPIPE and pipefail hides the match
	n="$("${READELF}" -r "${ko}" 2>/dev/null | grep -cE 'R_ARM_(GOT_BREL|GOTPC|GOT32|GOT_PREL|GOTOFF)' || true)"
	[ "${n:-0}" = 0 ] || bad="${bad} $(basename "${ko}")"
done < <(find "${MODROOT}/lib/modules/${KREL}" -name '*.ko')
[ -z "${bad}" ] || { echo "[kernel] ERROR: modules with GOT relocations 4.4 cannot load:${bad}"; exit 1; }
echo "[kernel] no module carries a GOT relocation"

cp -f "${KBUILD}/arch/arm/boot/Image" "${STAGE}/Image"
echo "[kernel] done: Image $(stat -c%s "${STAGE}/Image") bytes, modules -> ${MODROOT}/lib/modules/$(ls "${MODROOT}/lib/modules" 2>/dev/null | head -1)"
