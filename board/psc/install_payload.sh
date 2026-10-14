#!/bin/bash
#
# install_payload.sh - run by ABFlashKit during a flash, after boot.img went to BOOTIMG1.
#
# New kit (it carries abrootfs.squashfs): the root filesystem image goes to the stick, System/Kernel/, which the
# new /init reads. Nothing is written to /data: /data/autobleem (the legacy install) stays as the fallback boot
# and as the source of the one-time migration of pairings, WiFi and zone (abstate.sh, ab_migrate).
# Old kit (no squashfs): the legacy install into /data/autobleem, as before.
#
# The paths can be moved by AB_KIT / AB_STICK / AB_DATA / AB_TMP - scripts/test_install_payload.sh does that.

KIT="${AB_KIT:-/media/Apps/abflashkit/kernel}"
STICK="${AB_STICK:-/media}"
DATA="${AB_DATA:-/data}"
TMP="${AB_TMP:-/tmp}"

if [ -f "${KIT}/abrootfs.squashfs" ]; then
	echo Installing AutoBleem payload \(squashfs, to the stick\)
	DST="${STICK}/System/Kernel"
	fail() { echo "ERROR: $*" >&2; rm -f "${DST}/abrootfs.squashfs.tmp" "${DST}/abrootfs.squashfs.sha256.tmp"; exit 1; }

	command -v sha256sum >/dev/null 2>&1 || fail "no sha256sum on the console: cannot verify the copy"
	[ -s "${KIT}/abrootfs.squashfs" ] || fail "${KIT}/abrootfs.squashfs is empty"
	[ -s "${KIT}/abrootfs.squashfs.sha256" ] || fail "${KIT}/abrootfs.squashfs.sha256 is missing"
	WANT="$(cut -d' ' -f1 < "${KIT}/abrootfs.squashfs.sha256")"
	[ "${#WANT}" -eq 64 ] || fail "${KIT}/abrootfs.squashfs.sha256 does not hold a sha256"
	mkdir -p "${DST}" || fail "cannot make ${DST}"

	# temp name, verify what landed on the stick (not the source: a bad write is what must be caught), rename
	cp "${KIT}/abrootfs.squashfs" "${DST}/abrootfs.squashfs.tmp" || fail "cannot copy abrootfs.squashfs to ${DST}"
	sync
	GOT="$(sha256sum "${DST}/abrootfs.squashfs.tmp" | cut -d' ' -f1)"
	[ "${GOT}" = "${WANT}" ] || fail "sha256 of the copy on the stick is ${GOT}, the kit says ${WANT}"
	mv -f "${DST}/abrootfs.squashfs.tmp" "${DST}/abrootfs.squashfs" || fail "cannot rename abrootfs.squashfs"

	printf '%s  abrootfs.squashfs\n' "${WANT}" > "${DST}/abrootfs.squashfs.sha256.tmp" || fail "cannot write the sha256 file"
	mv -f "${DST}/abrootfs.squashfs.sha256.tmp" "${DST}/abrootfs.squashfs.sha256" || fail "cannot rename the sha256 file"
	sync
	echo "abrootfs.squashfs installed to ${DST} (sha256 ${WANT})"
	echo Done
	exit 0
fi

# ---- old kit: the legacy install on /data/autobleem ------------------------------------------------------------
mount -o remount,rw "${DATA}"

echo Installing AutoBleem payload \(legacy, to ${DATA}/autobleem\)
# What the user set up survives a flash: the WiFi (wpa_supplicant.conf, ssid.cfg) and the Bluetooth pairings
# (etc/bluetooth/bluetoothd, bind-mounted over /var/lib/bluetooth). Read through the running system's /etc,
# which is the overlay or the console's own root.
rm -rf "${TMP}/abkeep" && mkdir -p "${TMP}/abkeep"
[ -s /etc/wpa_supplicant.conf ] && cp -a /etc/wpa_supplicant.conf "${TMP}/abkeep/"
[ -s /etc/autobleem/ssid.cfg ] && cp -a /etc/autobleem/ssid.cfg "${TMP}/abkeep/"
[ -d "${DATA}/autobleem/rootfs/etc/bluetooth/bluetoothd" ] && cp -a "${DATA}/autobleem/rootfs/etc/bluetooth/bluetoothd" "${TMP}/abkeep/"

rm -rf "${DATA}/autobleem"
mkdir -p "${DATA}/autobleem/rootfs"
mkdir -p "${DATA}/autobleem/workdir"
# gunzip | tar, not tar -z: on a console flashed with the first Buildroot payload /bin/tar is a busybox
# without gzip, and this is what replaces that payload
gunzip -c "${KIT}/abrootfs.tgz" | tar -xvf - -C "${DATA}/autobleem/rootfs"

# Back into the NEW upper layer, never through /etc: while the payload runs, /etc is the overlay whose upper
# directory was just deleted, and a file written there is gone at the reboot - which is how every flash lost
# the WiFi (2026-09-26).
R="${DATA}/autobleem/rootfs"
[ -f "${TMP}/abkeep/wpa_supplicant.conf" ] && cp -a "${TMP}/abkeep/wpa_supplicant.conf" "$R/etc/wpa_supplicant.conf"
[ -f "${TMP}/abkeep/ssid.cfg" ] && mkdir -p "$R/etc/autobleem" && cp -a "${TMP}/abkeep/ssid.cfg" "$R/etc/autobleem/ssid.cfg"
if [ -d "${TMP}/abkeep/bluetoothd" ]; then
	rm -rf "$R/etc/bluetooth/bluetoothd"
	mkdir -p "$R/etc/bluetooth"
	cp -a "${TMP}/abkeep/bluetoothd" "$R/etc/bluetooth/bluetoothd"
fi
rm -rf "${TMP}/abkeep"
sync
echo Done
