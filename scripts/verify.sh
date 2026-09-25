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
	# its own listing: the coverage section above only makes one when the reference manifest is there
	SAFE_LIST="$(mktemp)"
	tar tzf "${OUT}/abrootfs.tgz" 2>/dev/null | sed 's#^\./##' | sort -u > "${SAFE_LIST}"
	links="$(tar tvzf "${OUT}/abrootfs.tgz" 2>/dev/null | awk '$1 ~ /^l/ {print $6}' | sed 's#^\./##' | grep -xE 'bin|lib|lib32|sbin' || true)"
	if [ -n "${links}" ]; then
		echo "  [UNSAFE] top-level symlinks: $(echo ${links}) - they would hide the console's own directories"
		unsafe=1
	fi
	inits="$(grep -E '(^|/)(systemd|systemd-udevd|init)$' "${SAFE_LIST}" | grep -vE '^etc/|/systemd/system$' || true)"
	if [ -n "${inits}" ]; then
		echo "  [UNSAFE] an init system of its own: $(echo ${inits})"
		unsafe=1
	fi
	# the console's own system: its /etc identity files, its D-Bus and its udev (post-build.sh removes them)
	shadows="$(grep -xE 'etc/(passwd|group|fstab|nsswitch\.conf|profile|os-release|mtab)|(usr/)?s?bin/(dbus-daemon|udevd|udevadm)|(usr/)?lib/lib(dbus-1|udev)\.so.*|etc/dbus-1/(system|session)\.conf|linuxrc' "${SAFE_LIST}" || true)"
	if [ -n "${shadows}" ]; then
		echo "  [UNSAFE] files that would replace the console's own: $(echo ${shadows})"
		unsafe=1
	fi
	# what the overlay switches on or off in the console's systemd: exactly the 2020 overlay's set (its units
	# enabled, the syslog whiteouts) - anything else in etc/systemd/system would change the console's services
	# (plus abbtagent, the Bluetooth agent package/abbtagent adds - started with bluetooth.target as bluetoothd is)
	allowed='etc/systemd/system/(bluetooth\.target\.wants/(bluetooth|abbtagent)|dbus-org\.bluez|syslog|multi-user\.target\.wants/(autobleem|dhclient|inetd|busybox-syslog|busybox-klogd))\.service'
	enabled="$(grep -E '^etc/systemd/system/.+\.(service|socket|target|timer|path|mount)$' "${SAFE_LIST}" | grep -vxE "${allowed}" || true)"
	if [ -n "${enabled}" ]; then
		echo "  [UNSAFE] units it would switch on in the console's systemd: $(echo ${enabled})"
		unsafe=1
	fi
	[ "${unsafe}" = 0 ] && echo "  [ok ] no top-level symlinks, no init, nothing of the console's system shadowed or switched on"
	# and against the console's real file list: nothing of it replaced beyond libraries and the 2020 set, every
	# 2020 tool path there, every program's libraries found (the checks above only know the names someone listed)
	python3 "${HERE}/scripts/overlay.py" check "${OUT}/abrootfs.tgz" || unsafe=1

	# The modules have to be loadable: modules.dep/modules.alias written by depmod (without them udev loads
	# nothing - cfg80211 and every WiFi driver stayed out on 2026-09-25: the build image had no depmod, and
	# the kernel's modules_install skips it with only a warning), under the release the kernel reports -
	# 4.4.22 as in 2020, not 4.4.22+ (the libs pack's xpad.ko, built for 2020's kernel, is refused).
	echo ""
	echo "== kernel modules =="
	kdirs="$(sed 's#/$##' "${SAFE_LIST}" | grep -E '^lib/modules/[^/]+$' | sort -u || true)"
	if [ "$(echo "${kdirs}" | grep -c .)" != 1 ]; then
		echo "  [BAD ] expected one lib/modules/<release>, found: $(echo ${kdirs})"
		unsafe=1
	else
		krel="${kdirs#lib/modules/}"
		case "${krel}" in *+) echo "  [BAD ] release ${krel}: the '+' of an untagged tree (LOCALVERSION= missing)"; unsafe=1 ;; esac
		for f in modules.dep modules.dep.bin modules.alias modules.alias.bin; do
			if grep -qx "${kdirs}/${f}" "${SAFE_LIST}"; then echo "  [ok ] ${kdirs}/${f}"
			else echo "  [BAD ] ${kdirs}/${f} missing - depmod did not run"; unsafe=1; fi
		done
		# pairings persist through the bind-mount of etc/bluetooth/bluetoothd over /var/lib/bluetooth
		if sed 's#/$##' "${SAFE_LIST}" | grep -qx 'etc/bluetooth/bluetoothd'; then
			echo "  [ok ] etc/bluetooth/bluetoothd (Bluetooth pairings outlive a reboot)"
		else
			echo "  [BAD ] etc/bluetooth/bluetoothd missing - every pairing would be lost at the next boot"; unsafe=1
			echo "         the tarball's etc/bluetooth entries: $(grep '^etc/bluetooth' "${SAFE_LIST}" | tr '\n' ' ')"
		fi
		# WiFi joins a network only through dhcpcd's wpa_supplicant hook (post-build.sh enables it)
		if grep -qx 'lib/dhcpcd/dhcpcd-hooks/10-wpa_supplicant' "${SAFE_LIST}"; then
			echo "  [ok ] lib/dhcpcd/dhcpcd-hooks/10-wpa_supplicant (dhcpcd starts wpa_supplicant)"
		else
			echo "  [BAD ] lib/dhcpcd/dhcpcd-hooks/10-wpa_supplicant missing - WiFi would never join a network"; unsafe=1
		fi
		# the console's udev has no rule that loads a module for a new device (Sony left 80-drivers.rules out)
		if grep -qx 'etc/udev/rules.d/80-autobleem-modules.rules' "${SAFE_LIST}"; then
			echo "  [ok ] etc/udev/rules.d/80-autobleem-modules.rules (modules load when their device appears)"
		else
			echo "  [BAD ] etc/udev/rules.d/80-autobleem-modules.rules missing - no module would ever load"; unsafe=1
		fi
	fi
	rm -f "${SAFE_LIST}"
fi
exit "${unsafe}"
