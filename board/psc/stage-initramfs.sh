#!/usr/bin/env bash
#
# stage-initramfs.sh — sourced by build-kernel.sh: stage the folder the kernel packs as its initramfs
# (CONFIG_INITRAMFS_SOURCE="initramfs").
#
# The folder is built from an explicit list, not copied whole: psc-kernel's initramfs/ also holds src/, the C
# source of the new /init, and that must not land in the image. The 2020 initramfs is the one file `init`
# (a static ARM binary; the busybox shell version lives in "busybox init/", outside initramfs/).
#
#   stage_initramfs <kernel-src> <dest> <legacy|new> <cross-prefix> <scratch-dir>
#
#   legacy  copies <kernel-src>/initramfs/init unchanged (same bytes, mode and mtime as the old whole-folder copy)
#   new     cross-compiles <kernel-src>/initramfs/src with <cross-prefix> and stages the result as /init
#
INITRAMFS_FILES=(init)

stage_initramfs(){
	local ksrc="$1" dest="$2" mode="$3" cross="$4" scratch="$5" f
	local idir="${ksrc}/initramfs"
	[ -d "${idir}" ] || { echo "[kernel] ERROR: no ${idir}"; return 1; }
	rm -rf "${dest}"; mkdir -p "${dest}"
	case "${mode}" in
		legacy)
			for f in "${INITRAMFS_FILES[@]}"; do
				[ -f "${idir}/${f}" ] || { echo "[kernel] ERROR: no ${idir}/${f}"; return 1; }
				cp -a "${idir}/${f}" "${dest}/${f}"
			done;;
		new)
			[ -f "${idir}/src/Makefile" ] || {
				echo "[kernel] ERROR: AB_INIT=new needs ${idir}/src (psc-kernel at feature/autobleem-33 or later)"; return 1; }
			# built in a copy: the kernel submodule stays clean
			rm -rf "${scratch}"; mkdir -p "${scratch}"
			cp -a "${idir}/src/." "${scratch}/"
			make -C "${scratch}" CROSS_COMPILE="${cross}" abinit >&2 || { echo "[kernel] ERROR: abinit build failed"; return 1; }
			[ -s "${scratch}/abinit" ] || { echo "[kernel] ERROR: abinit build made no binary"; return 1; }
			install -m 0755 "${scratch}/abinit" "${dest}/init";;
		*) echo "[kernel] ERROR: AB_INIT must be legacy or new, not '${mode}'"; return 1;;
	esac
	echo "[kernel] initramfs (AB_INIT=${mode}): $(cd "${dest}" && find . -type f | sort | tr '\n' ' ')"
}
