#!/usr/bin/env bash
#
# post-image.sh — assemble the abflashkit "kernel/" payload from Buildroot output.
#
# Buildroot calls this with $1 = $BINARIES_DIR (output/images) and exports
# BR2_EXTERNAL_PSC_PATH, HOST_DIR, TARGET_DIR, BUILD_DIR, BASE_DIR.
#
# Produces  $BINARIES_DIR/psc-payload/kernel/ :
#   boot.img          FIT image (lz4 Image + orig.dtb), dd'd to BOOTIMG1
#   boot.md5          md5sum of boot.img (what abflashkit verifies)
#   abrootfs.tgz      the rootfs overlay, unpacked to /data/autobleem/rootfs
#   abrootfs.md5      md5 of abrootfs.tgz (informational; the tool never checks it)
#   recovery-on.img   16-byte MISC recovery flag = ON
#   recovery-off.img  16-byte MISC recovery flag = OFF
#   install_payload.sh
#
set -euo pipefail

BINARIES_DIR="${1:-$BINARIES_DIR}"
BOARD_DIR="${BR2_EXTERNAL_PSC_PATH}/board/psc"
OUT="${BINARIES_DIR}/psc-payload/kernel"
WORK="${BINARIES_DIR}/psc-payload/.work"

echo "[post-image] assembling abflashkit payload -> ${OUT}"
rm -rf "${OUT}" "${WORK}"
mkdir -p "${OUT}" "${WORK}"

# --- 1. boot.img : uncompressed Image -> lz4 (+8-byte LE size) -> FIT ---------
# The kernel is built separately (gcc-6) into $(O)/kernel-stage/Image.
KIMAGE="${BASE_DIR:-}/kernel-stage/Image"
[ -f "${KIMAGE}" ] || KIMAGE="${BINARIES_DIR}/Image"   # fallback if Buildroot built it
if [ ! -f "${KIMAGE}" ]; then
	echo "[post-image] ERROR: no kernel Image (looked in kernel-stage and ${BINARIES_DIR})"; exit 1
fi
cp "${KIMAGE}"                  "${WORK}/Image"
cp "${BOARD_DIR}/kernel.its"    "${WORK}/kernel.its"
cp "${BOARD_DIR}/orig.dtb"      "${WORK}/orig.dtb"

LZ4="${HOST_DIR}/bin/lz4";     [ -x "${LZ4}" ]     || LZ4="$(command -v lz4)"
MKIMAGE="${HOST_DIR}/bin/mkimage"; [ -x "${MKIMAGE}" ] || MKIMAGE="$(command -v mkimage)"
[ -x "${LZ4}" ]     || { echo "[post-image] ERROR: no lz4 (host-lz4 or system)"; exit 1; }
[ -x "${MKIMAGE}" ] || { echo "[post-image] ERROR: no mkimage (host-uboot-tools or system u-boot-tools)"; exit 1; }
( cd "${WORK}"
  "${LZ4}" -lf9 Image Image.lz4
  # append original (uncompressed) size as 8 hex digits, little-endian — the
  # legacy MTK lz4 loader expects it (identical to uboot-support/packit.sh).
  printf "%.8x" "$(stat -c '%s' Image)" \
    | sed 's/\(..\)\(..\)\(..\)\(..\)/\4\3\2\1/g' | xxd -r -p >> Image.lz4
  "${MKIMAGE}" -f kernel.its boot.img )

cp "${WORK}/boot.img" "${OUT}/boot.img"
( cd "${OUT}" && md5sum boot.img > boot.md5 )
echo "[post-image] boot.img  $(stat -c '%s' "${OUT}/boot.img") bytes  md5=$(cut -d' ' -f1 "${OUT}/boot.md5")"

# --- 2. abrootfs.tgz : the rootfs Buildroot tarred --------------------------
if [ ! -f "${BINARIES_DIR}/rootfs.tar.gz" ]; then
	echo "[post-image] ERROR: ${BINARIES_DIR}/rootfs.tar.gz not found (enable BR2_TARGET_ROOTFS_TAR_GZIP)"; exit 1
fi
cp "${BINARIES_DIR}/rootfs.tar.gz" "${OUT}/abrootfs.tgz"
( cd "${OUT}" && md5sum abrootfs.tgz | cut -d' ' -f1 > abrootfs.md5 )
echo "[post-image] abrootfs.tgz $(stat -c '%s' "${OUT}/abrootfs.tgz") bytes"

# --- 3. static payload bits -------------------------------------------------
# recovery flags: 16 bytes. ON = MISC command 2 at offset 8; OFF = all zero.
printf '\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x00\x00\x00\x00\x00\x00' > "${OUT}/recovery-on.img"
printf '\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00' > "${OUT}/recovery-off.img"
cp "${BOARD_DIR}/install_payload.sh" "${OUT}/install_payload.sh"
chmod +x "${OUT}/install_payload.sh"

echo "[post-image] payload ready:"
ls -la "${OUT}"
