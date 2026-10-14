#!/usr/bin/env bash
#
# test_install_payload.sh — host test of board/psc/install_payload.sh (run by ABFlashKit during a flash) against
# a fake /media (kit + stick) and a fake /data: the squashfs path copies to System/Kernel with a verified
# rename and never touches /data; a bad sha256 / missing file fails loudly and leaves the old image; an old kit
# (no squashfs) still takes the legacy path. No console, no root needed.
#
# Usage: scripts/test_install_payload.sh
#
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${HERE}/board/psc/install_payload.sh"
T="$(mktemp -d)"
trap 'rm -rf "${T}"' EXIT
fail=0
ok(){ printf 'ok   %s\n' "$*"; }
bad(){ printf 'FAIL %s\n' "$*"; fail=1; }
check(){ local what="$1"; shift; if "$@"; then ok "${what}"; else bad "${what}"; fi; }

check "bash -n install_payload.sh" bash -n "${SCRIPT}"

STUB="${T}/stubs"; LOG="${T}/cmds.log"; mkdir -p "${STUB}"
printf '#!/bin/sh\necho "mount $*" >> "%s"\n' "${LOG}" > "${STUB}/mount"
chmod +x "${STUB}/mount"
export PATH="${STUB}:${PATH}"

world() {  # fresh fake world: kit with a squashfs, stick, /data with a legacy install
	rm -rf "${T}/media" "${T}/data" "${T}/tmp"; : > "${LOG}"
	export AB_KIT="${T}/media/Apps/abflashkit/kernel" AB_STICK="${T}/media" AB_DATA="${T}/data" AB_TMP="${T}/tmp"
	mkdir -p "${AB_KIT}" "${AB_STICK}/System" "${AB_DATA}/autobleem/rootfs/etc/bluetooth/bluetoothd" "${AB_TMP}"
	head -c 100000 /dev/urandom > "${AB_KIT}/abrootfs.squashfs"
	( cd "${AB_KIT}" && sha256sum abrootfs.squashfs > abrootfs.squashfs.sha256 )
	echo PAIRING > "${AB_DATA}/autobleem/rootfs/etc/bluetooth/bluetoothd/info"
	echo marker > "${AB_DATA}/autobleem/sentinel"
	DSUM="$(cd "${T}/data" && find . -type f -o -type d | sort | xargs stat -c '%n %a %Y %s')"
}
data_same(){ test "$(cd "${T}/data" && find . -type f -o -type d | sort | xargs stat -c '%n %a %Y %s')" = "${DSUM}"; }

# 1. new kit: copied, verified, renamed; /data untouched, not remounted
world
bash "${SCRIPT}" > "${T}/out" 2>&1; rc=$?
check "new kit: exit 0"                               test "${rc}" -eq 0
K="${AB_STICK}/System/Kernel"
check "new kit: squashfs on the stick (identical)"    cmp -s "${AB_KIT}/abrootfs.squashfs" "${K}/abrootfs.squashfs"
check "new kit: sha256 file on the stick"             test "$(cut -d' ' -f1 "${K}/abrootfs.squashfs.sha256")" = "$(cut -d' ' -f1 "${AB_KIT}/abrootfs.squashfs.sha256")"
check "new kit: sha256 verifies in System/Kernel"     bash -c "cd '${K}' && sha256sum -c abrootfs.squashfs.sha256 >/dev/null"
check "new kit: no temp files left"                   test -z "$(ls "${K}" | grep tmp)"
check "new kit: /data/autobleem untouched"            data_same
check "new kit: /data not remounted"                  test ! -s "${LOG}"
check "new kit: prints Done"                          grep -q '^Done$' "${T}/out"

# 2. new kit over an older image on the stick: replaced
world; mkdir -p "${AB_STICK}/System/Kernel"; echo OLD > "${AB_STICK}/System/Kernel/abrootfs.squashfs"
bash "${SCRIPT}" > /dev/null 2>&1
check "replace: old image replaced"                   cmp -s "${AB_KIT}/abrootfs.squashfs" "${AB_STICK}/System/Kernel/abrootfs.squashfs"

# 3. wrong sha256 in the kit: fails loudly, the old image stays, nothing left behind, /data untouched
world; mkdir -p "${AB_STICK}/System/Kernel"; echo OLD > "${AB_STICK}/System/Kernel/abrootfs.squashfs"
printf '%064d  abrootfs.squashfs\n' 0 > "${AB_KIT}/abrootfs.squashfs.sha256"
bash "${SCRIPT}" > "${T}/out" 2> "${T}/err"; rc=$?
check "bad sha256: non-zero exit"                     test "${rc}" -ne 0
check "bad sha256: ERROR on stderr"                   grep -q '^ERROR: ' "${T}/err"
check "bad sha256: old image kept"                    test "$(cat "${AB_STICK}/System/Kernel/abrootfs.squashfs")" = OLD
check "bad sha256: no temp left"                      test -z "$(ls "${AB_STICK}/System/Kernel" | grep tmp)"
check "bad sha256: no Done printed"                   test -z "$(grep '^Done$' "${T}/out")"
check "bad sha256: /data untouched"                   data_same

# 4. sha256 file missing / garbage / empty squashfs
world; rm -f "${AB_KIT}/abrootfs.squashfs.sha256"
bash "${SCRIPT}" > /dev/null 2>&1; rc=$?
check "no sha256 file: fails, nothing copied"         test "${rc}" -ne 0 -a ! -e "${AB_STICK}/System/Kernel/abrootfs.squashfs"
world; echo garbage > "${AB_KIT}/abrootfs.squashfs.sha256"
bash "${SCRIPT}" > /dev/null 2>&1; rc=$?
check "garbage sha256 file: fails"                    test "${rc}" -ne 0 -a ! -e "${AB_STICK}/System/Kernel/abrootfs.squashfs"
world; : > "${AB_KIT}/abrootfs.squashfs"
bash "${SCRIPT}" > /dev/null 2>&1; rc=$?
check "empty squashfs: fails"                         test "${rc}" -ne 0

# 5. a corrupt copy (cp that damages the file) is caught by the check on the stick's copy
world
printf '#!/bin/sh\nfor a; do d="$a"; done\n/bin/cp "$@" && printf X >> "$d"\n' > "${STUB}/cp"; chmod +x "${STUB}/cp"
bash "${SCRIPT}" > /dev/null 2> "${T}/err"; rc=$?
rm -f "${STUB}/cp"
check "corrupt copy: fails and says so"               test "${rc}" -ne 0 && grep -q 'sha256 of the copy' "${T}/err"
check "corrupt copy: nothing installed"               test ! -e "${AB_STICK}/System/Kernel/abrootfs.squashfs"

# 6. old kit (no squashfs): the legacy install into /data/autobleem, as before
world; rm -f "${AB_KIT}/abrootfs.squashfs" "${AB_KIT}/abrootfs.squashfs.sha256"
( mkdir -p "${T}/tree/etc" && echo NEW > "${T}/tree/etc/newfile" && tar -C "${T}/tree" -cf - . | gzip > "${AB_KIT}/abrootfs.tgz" )
bash "${SCRIPT}" > "${T}/out" 2>&1; rc=$?
check "old kit: exit 0"                               test "${rc}" -eq 0
check "old kit: rootfs unpacked to /data/autobleem"   test "$(cat "${AB_DATA}/autobleem/rootfs/etc/newfile")" = NEW
check "old kit: pairings carried over"                test "$(cat "${AB_DATA}/autobleem/rootfs/etc/bluetooth/bluetoothd/info")" = PAIRING
check "old kit: /data remounted rw"                   grep -q "^mount -o remount,rw ${AB_DATA}$" "${LOG}"
check "old kit: nothing on the stick"                 test ! -e "${AB_STICK}/System/Kernel"

if [ "${fail}" -eq 0 ]; then echo "ALL OK"; else echo "FAILED"; fi
exit "${fail}"
