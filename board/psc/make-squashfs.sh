#!/usr/bin/env bash
#
# make-squashfs.sh — pack the rootfs tree into abrootfs.squashfs, the image the new /init (initramfs/src of
# psc-kernel) copies from the stick into RAM and mounts as the top layer of the root overlay.
#
#   make-squashfs.sh <tree> <out.squashfs>
#
# Called from post-fakeroot.sh, so <tree> is the very tree Buildroot tars into abrootfs.tgz, seen under the same
# fakeroot (owners, modes, the device-table whiteouts). Options: xz with the ARM BCJ filter (the kernel has
# SQUASHFS_XZ and XZ_DEC_ARM), 256K blocks (the 4.4 squashfs runs with a single decompressor), everything owned by
# root, never appended to an old image.
#
set -euo pipefail
TREE="${1:?tree}"; OUT="${2:?output file}"

MKSQUASHFS="${HOST_DIR:+${HOST_DIR}/bin/mksquashfs}"
[ -x "${MKSQUASHFS:-}" ] || MKSQUASHFS="$(command -v mksquashfs || true)"
[ -n "${MKSQUASHFS}" ] || { echo "[squashfs] ERROR: no mksquashfs (BR2_PACKAGE_HOST_SQUASHFS=y in the defconfig)"; exit 1; }
[ -d "${TREE}" ] || { echo "[squashfs] ERROR: no tree ${TREE}"; exit 1; }

rm -f "${OUT}"
"${MKSQUASHFS}" "${TREE}" "${OUT}" -comp xz -Xbcj arm -b 256K -all-root -noappend -no-progress >/dev/null
[ -s "${OUT}" ] || { echo "[squashfs] ERROR: mksquashfs made no image"; exit 1; }
echo "[squashfs] $(basename "${OUT}") $(stat -c '%s' "${OUT}") bytes"
