#!/usr/bin/env bash
#
# test_abstate.sh — host test of board/psc/overlay/etc/autobleem/abstate.sh (the stick-boot helpers of
# AUTOBLEEM-33) against fake roots: mode detection, the WiFi copy-in/copy-back, the timezone replay and the
# Bluetooth image (mount, umount and mke2fs are stubs that record their command line), plus `sh -n` / `bash -n`
# on every script of the change. No console, no root, no loop device needed.
#
# Usage: scripts/test_abstate.sh
#
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OV="${HERE}/board/psc/overlay"
T="$(mktemp -d)"
trap 'rm -rf "${T}"' EXIT
fail=0
ok(){ printf 'ok   %s\n' "$*"; }
bad(){ printf 'FAIL %s\n' "$*"; fail=1; }
check(){ local what="$1"; shift; if "$@"; then ok "${what}"; else bad "${what}"; fi; }

# --- syntax: each script in the shell it runs under ----------------------------------------------------------
for f in etc/autobleem/abstate etc/autobleem/abstate.sh bin/start_pman usr/bin/start_pman; do
	check "sh -n ${f}" sh -n "${OV}/${f}"
done
for f in etc/autobleem/bluetooth etc/autobleem/autobleem bin/settime; do
	check "bash -n ${f}" bash -n "${OV}/${f}"
done
check "bash -n post-build.sh" bash -n "${HERE}/board/psc/post-build.sh"
if command -v dash >/dev/null; then
	check "dash -n abstate.sh (POSIX)" dash -n "${OV}/etc/autobleem/abstate.sh"
fi

# --- a fake world ----------------------------------------------------------------------------------------------
export AB_RUN="${T}/run" AB_ETC="${T}/etc" AB_STICK="${T}/media" AB_ZONEINFO="${T}/zoneinfo"
export AB_BT_DIR="${T}/var/lib/bluetooth" AB_MOUNTS="${T}/mounts" AB_STICK_WAIT=0
STUB="${T}/stubs"; LOG="${T}/cmds.log"
mkdir -p "${AB_RUN}" "${AB_ETC}/autobleem" "${AB_STICK}" "${AB_ZONEINFO}/Europe" "${STUB}"
: > "${LOG}"
printf 'x\n' > "${AB_ZONEINFO}/Europe/Dublin"; printf 'x\n' > "${AB_ZONEINFO}/UTC"
for c in mount umount sync; do
	printf '#!/bin/sh\necho "%s $*" >> "%s"\n' "${c}" "${LOG}" > "${STUB}/${c}"
done
# the stub mke2fs makes the file look like a filesystem
printf '#!/bin/sh\necho "mke2fs $*" >> "%s"\nfor a; do f="$a"; done\necho EXT4 > "$f"\n' "${LOG}" > "${STUB}/mke2fs"
chmod +x "${STUB}"/*
export PATH="${STUB}:${PATH}"

# shellcheck source=board/psc/overlay/etc/autobleem/abstate.sh
. "${OV}/etc/autobleem/abstate.sh"

mounts_legacy(){ printf 'overlay / overlay rw,lowerdir=/newroot,upperdir=/data/autobleem/rootfs,workdir=/data/autobleem/workdir 0 0\n/dev/mmcblk0p10 /data ext4 rw,relatime 0 0\n' > "${AB_MOUNTS}"; }
mounts_new(){ printf 'overlay / overlay rw,lowerdir=/squashfs:/newroot,upperdir=/abrw/upper,workdir=/abrw/work 0 0\n/dev/mmcblk0p10 /data ext4 ro,noload 0 0\n' > "${AB_MOUNTS}"; }
stick_up(){ printf '/dev/sda1 %s vfat rw 0 0\n' "${AB_STICK}" >> "${AB_MOUNTS}"; }
reset(){ rm -rf "${AB_RUN:?}"/* "${AB_STICK:?}"/* "${AB_ETC:?}"/wpa_supplicant.conf "${AB_ETC}/autobleem/ssid.cfg" \
	"${AB_ETC}/localtime" "${AB_ETC}/timezone" "${T}/var"; : > "${LOG}"; }

# --- mode ----------------------------------------------------------------------------------------------------------
mounts_legacy;  check "mode: legacy (upper on /data, data rw)"           test "$(ab_mode)" = legacy
mounts_new;     check "mode: new (upper /abrw, data ro)"                  test "$(ab_mode)" = new
printf 'overlay / overlay rw,upperdir=/abrw/upper,workdir=/abrw/work 0 0\n/dev/mmcblk0p10 /data ext4 rw 0 0\n' > "${AB_MOUNTS}"
                check "mode: new by the upperdir alone"                   test "$(ab_mode)" = new
printf 'overlay / overlay rw,upperdir=/data/autobleem/rootfs 0 0\n/dev/mmcblk0p10 /data ext4 ro,noload 0 0\n' > "${AB_MOUNTS}"
                check "mode: new by /data ro alone"                       test "$(ab_mode)" = new
printf 'overlay / overlay rw,upperdir=/data/autobleem/rootfs 0 0\n/dev/mmcblk0p10 /data ext4 rw,errors=ro 0 0\n' > "${AB_MOUNTS}"
                check "mode: errors=ro is not ro"                         test "$(ab_mode)" = legacy
printf '/dev/mmcblk0p7 / ext4 ro 0 0\n/dev/mmcblk0p10 /data ext4 rw 0 0\n' > "${AB_MOUNTS}"
                check "mode: stock boot is legacy"                        test "$(ab_mode)" = legacy
mounts_legacy; echo stick > "${AB_RUN}/mode"
                check "mode: marker file wins"                            test "$(ab_mode)" = new
rm -f "${AB_RUN}/mode"

# --- stick -------------------------------------------------------------------------------------------------------
mounts_new
check "stick: not mounted -> fails, no folder made"  bash -c ". '${OV}/etc/autobleem/abstate.sh'; ! ab_stick_data 0 >/dev/null; test ! -e '${AB_STICK}/System'"
stick_up
check "stick: mounted -> System/Data"                test "$(ab_stick_data 0)" = "${AB_STICK}/System/Data"

# --- WiFi ----------------------------------------------------------------------------------------------------------
reset; mounts_new; stick_up
printf 'update_config=1\n' > "${AB_ETC}/wpa_supplicant.conf"
mkdir -p "${AB_STICK}/System/Data/wifi"
printf 'network={ssid="home"}\n' > "${AB_STICK}/System/Data/wifi/wpa_supplicant.conf"
printf 'home\n' > "${AB_STICK}/System/Data/wifi/ssid.cfg"
ab_wifi_in
check "wifi-in: wpa_supplicant.conf from the stick"  grep -q home "${AB_ETC}/wpa_supplicant.conf"
check "wifi-in: mode 600"                            test "$(stat -c %a "${AB_ETC}/wpa_supplicant.conf")" = 600
check "wifi-in: ssid.cfg from the stick"             test "$(cat "${AB_ETC}/autobleem/ssid.cfg")" = home
check "wifi-in: marker made"                         test -e "${AB_RUN}/wifi-synced"
printf 'network={ssid="work"}\n' > "${AB_ETC}/wpa_supplicant.conf"
ab_wifi_in
check "wifi-in: only once per boot"                  grep -q work "${AB_ETC}/wpa_supplicant.conf"
ab_wifi_out
check "wifi-out: changed file copied to the stick"   grep -q work "${AB_STICK}/System/Data/wifi/wpa_supplicant.conf"
check "wifi-out: unchanged ssid.cfg kept"            test "$(cat "${AB_STICK}/System/Data/wifi/ssid.cfg")" = home
check "wifi-out: no temp file left"                  test -z "$(ls "${AB_STICK}/System/Data/wifi" | grep tmp)"

# the shipped default must never overwrite the stick's master when the stick was not seen at start
reset; mounts_new
printf 'update_config=1\n' > "${AB_ETC}/wpa_supplicant.conf"
ab_wifi_in; stick_up
mkdir -p "${AB_STICK}/System/Data/wifi"; printf 'MASTER\n' > "${AB_STICK}/System/Data/wifi/wpa_supplicant.conf"
ab_wifi_out
check "wifi-out: nothing before the stick was seen"  grep -q MASTER "${AB_STICK}/System/Data/wifi/wpa_supplicant.conf"
check "wifi-in: no stick -> no marker"               test ! -e "${AB_RUN}/wifi-synced"

# first use: the stick has no WiFi folder yet, the user saves a network
reset; mounts_new; stick_up
printf 'update_config=1\n' > "${AB_ETC}/wpa_supplicant.conf"
ab_wifi_in
printf 'network={ssid="new"}\n' >> "${AB_ETC}/wpa_supplicant.conf"
ab_wifi_out
check "wifi first use: saved to a new wifi folder"   grep -q new "${AB_STICK}/System/Data/wifi/wpa_supplicant.conf"

# legacy: nothing at all
reset; mounts_legacy; stick_up
printf 'update_config=1\n' > "${AB_ETC}/wpa_supplicant.conf"
ab_wifi_in; ab_wifi_out
check "legacy: wifi helpers touch nothing"           test ! -e "${AB_STICK}/System" -a ! -e "${AB_RUN}/wifi-synced"

# --- timezone -----------------------------------------------------------------------------------------------------
reset; mounts_new; stick_up
ab_tz_save Europe/Dublin
check "tz-save: name on the stick"                   test "$(cat "${AB_STICK}/System/Data/timezone")" = Europe/Dublin
ab_tz_in
check "tz-in: localtime link"                        test "$(readlink "${AB_ETC}/localtime")" = "${AB_ZONEINFO}/Europe/Dublin"
check "tz-in: /etc/timezone"                         test "$(cat "${AB_ETC}/timezone")" = Europe/Dublin
for bad_z in ../etc/passwd /UTC Nowhere/Place ""; do
	reset; mounts_new; stick_up; mkdir -p "${AB_STICK}/System/Data"; printf '%s\n' "${bad_z}" > "${AB_STICK}/System/Data/timezone"
	ab_tz_in 2>/dev/null
	check "tz-in: refuses '${bad_z}'"                test ! -e "${AB_ETC}/localtime"
done
reset; mounts_new; ab_tz_save UTC 2>/dev/null
check "tz-save: no stick -> nothing written"         test ! -e "${AB_STICK}/System"
reset; mounts_legacy; stick_up; ab_tz_save UTC; ab_tz_in
check "legacy: tz helpers touch nothing"             test ! -e "${AB_STICK}/System" -a ! -e "${AB_ETC}/localtime"

# --- Bluetooth ----------------------------------------------------------------------------------------------------
reset; mounts_legacy
ab_bt_mount
check "bt legacy: bind mount of the overlay folder"  grep -q "^mount --bind /etc/bluetooth/bluetoothd ${AB_BT_DIR}$" "${LOG}"
check "bt legacy: nothing on the stick"              test ! -e "${AB_STICK}/System"
ab_bt_umount
check "bt legacy: no umount"                         test ! "$(grep -c umount "${LOG}")" -gt 0

reset; mounts_new
ab_bt_mount 2>/dev/null
check "bt new, no stick: no mount, folder exists"    test -d "${AB_BT_DIR}" -a ! -s "${LOG}"

reset; mounts_new; stick_up
ab_bt_mount
IMG="${AB_STICK}/System/Data/bluetooth.img"
check "bt new: image made"                           test -f "${IMG}"
check "bt new: mke2fs -t ext4 -F"                    grep -q "^mke2fs -t ext4 -F .*bluetooth.img.new$" "${LOG}"
check "bt new: loop ext4 mount over the folder"      grep -q "^mount -t ext4 -o loop,noatime ${IMG} ${AB_BT_DIR}$" "${LOG}"
check "bt new: no temp image left"                   test ! -e "${IMG}.new"
: > "${LOG}"; echo EXISTING > "${IMG}"
ab_bt_mount
check "bt new: existing image kept, not remade"      test "$(cat "${IMG}")" = EXISTING -a -z "$(grep mke2fs "${LOG}")"
printf '%s %s ext4 rw 0 0\n' "/dev/loop0" "${AB_BT_DIR}" >> "${AB_MOUNTS}"; : > "${LOG}"
ab_bt_mount
check "bt new: already mounted -> no second mount"   test ! -s "${LOG}"
ab_bt_umount
check "bt new: sync + umount -d"                     grep -q "^umount -d ${AB_BT_DIR}$" "${LOG}"

if [ "${fail}" -eq 0 ]; then echo "ALL OK"; else echo "FAILED"; fi
exit "${fail}"
