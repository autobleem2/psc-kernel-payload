#!/usr/bin/env bash
#
# verify.sh — sanity-check a freshly built payload against the reference.
#
# The reference is the CURRENTLY SHIPPING payload from autobleem2/autobleem
# (payload/Apps/abflashkit/kernel). A from-source rebuild is NOT expected to be
# byte-identical (different Buildroot build), so this checks structure and the
# things that actually matter at flash time, not md5 equality of the tarball.
#
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-${HERE}/output/images/psc-payload/kernel}"
REF="${HERE}/reference"

[ -d "${OUT}" ] || { echo "no built payload at ${OUT}"; exit 1; }
echo "== built payload: ${OUT} =="
ls -la "${OUT}"

echo ""
echo "== boot.img =="
if [ -f "${OUT}/boot.img" ]; then
	NEW=$(md5sum "${OUT}/boot.img" | cut -d' ' -f1)
	echo "built boot.img md5      : ${NEW}"
	echo "reference (shipped) md5 : $(cat "${REF}/boot.md5" 2>/dev/null || echo '?')"
	# FIT header sanity
	head -c 4 "${OUT}/boot.img" | xxd | grep -q "d00d feed" \
		&& echo "FIT magic               : OK (d00dfeed)" \
		|| echo "FIT magic               : MISSING — not a valid FIT image!"
fi

echo ""
echo "== abrootfs.tgz coverage vs reference manifest =="
if [ -f "${OUT}/abrootfs.tgz" ] && [ -f "${REF}/abrootfs.files.txt" ]; then
	tar tzf "${OUT}/abrootfs.tgz" 2>/dev/null | sed 's#^\./##' | sort -u > /tmp/new.files
	sort -u "${REF}/abrootfs.files.txt" > /tmp/ref.files
	echo "reference files : $(wc -l < /tmp/ref.files)"
	echo "built files     : $(wc -l < /tmp/new.files)"
	echo "-- key binaries the flasher/overlay needs, present in build? --"
	for f in bin/busybox usr/libexec/bluetooth/bluetoothd usr/lib/bluetooth/plugins/sixaxis.so \
	         bin/wpa_supplicant bin/dropbear bin/ntfs-3g bin/hciconfig bin/iw \
	         lib/modules; do
		if grep -q "^${f}" /tmp/new.files; then echo "  [ok ] ${f}"; else echo "  [MISS] ${f}"; fi
	done
else
	echo "(reference manifest or built tgz missing)"
fi

# SAFETY - the overlay is laid over the console's own root. Two things in it would stop the console
# booting, so they fail the build (and CI) instead of reaching a flash:
#   * bin/, lib/, sbin/ as symlinks (Buildroot's merged /usr): the upper-layer symlink hides the console's
#     real /lib - systemd, firmware and Sony's libraries included - and redirects it into the overlay.
#   * an init of its own (systemd, udevd, /sbin/init): with the above, Buildroot's systemd would run as
#     PID 1 over Sony's units. The shipped overlay carries glibc and tools, never an init.
# BR2_INIT_SYSTEMD forces merged /usr; the fix is BR2_INIT_NONE with the needed units in board/psc/overlay.
echo ""
echo "== overlay safety (must not break the console's root) =="
unsafe=0
if [ -f "${OUT}/abrootfs.tgz" ]; then
	links="$(tar tvzf "${OUT}/abrootfs.tgz" 2>/dev/null | awk '$1 ~ /^l/ {print $6}' | sed 's#^\./##' | grep -xE 'bin|lib|lib32|sbin' || true)"
	if [ -n "${links}" ]; then
		echo "  [UNSAFE] top-level symlinks: $(echo ${links}) - they would hide the console's own directories"
		unsafe=1
	fi
	inits="$(grep -E '(^|/)(systemd|systemd-udevd|init)$' /tmp/new.files 2>/dev/null | grep -vE '^etc/|/systemd/system$' || true)"
	if [ -n "${inits}" ]; then
		echo "  [UNSAFE] an init system of its own: $(echo ${inits})"
		unsafe=1
	fi
	[ "${unsafe}" = 0 ] && echo "  [ok ] no top-level symlinks, no init of its own"
fi
exit "${unsafe}"
