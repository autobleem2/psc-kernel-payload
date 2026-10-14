# Sourced by the AutoBleem scripts (POSIX sh: it runs under bash and under the console's busybox ash).
#
# The new /init (stick path, AUTOBLEEM-33) runs the console with a tmpfs upper layer and /data (mmcblk0p10)
# read-write for Sony (the stick's boot.sh makes it read-only only while the AutoBleem launcher runs): whatever
# is written below / is gone at the next reboot. What must outlive a reboot lives
# on the stick, in $AB_STICK/System/Data. In the legacy boot (overlay upper on /data/autobleem) none of this
# applies and every function here either does nothing or does what the scripts did before.
#
# Every path can be moved below a fake root by the AB_* variables - scripts/test_abstate.sh does that.

AB_MOUNTS="${AB_MOUNTS:-/proc/mounts}"
AB_RUN="${AB_RUN:-/run/autobleem}"
AB_ETC="${AB_ETC:-/etc}"
AB_STICK="${AB_STICK:-/media}"
AB_STICK_WAIT="${AB_STICK_WAIT:-30}"
AB_ZONEINFO="${AB_ZONEINFO:-/usr/share/zoneinfo}"
AB_BT_DIR="${AB_BT_DIR:-/var/lib/bluetooth}"
AB_BT_IMG_MB="${AB_BT_IMG_MB:-4}"

ab_log() { echo "abstate: $*" >&2; }

# ab_mode: prints "new" or "legacy". New = the stick boot of the new /init. The init leaves no marker, so:
#   1. $AB_RUN/mode reading "stick" (reserved: honoured if a later init writes it);
#   2. the root overlay's upperdir is below /abrw (the init's tmpfs for upper and work);
#   3. /data is mounted read-only (the legacy boot keeps it read-write: its upper layer is there; the stick
#      boot's boot.sh makes it read-only while the launcher runs).
ab_mode() {
	if [ -r "${AB_RUN}/mode" ]; then
		read -r ab_m < "${AB_RUN}/mode"
		if [ "${ab_m}" = stick ]; then echo new; return 0; fi
	fi
	ab_root_opts=""
	ab_data_opts=""
	while read -r ab_dev ab_mp ab_type ab_opts ab_rest; do
		case "${ab_mp}" in
		/) [ "${ab_type}" = overlay ] && ab_root_opts="${ab_opts}" ;;
		/data) ab_data_opts="${ab_opts}" ;;
		esac
	done < "${AB_MOUNTS}"
	case "${ab_root_opts}" in
	*upperdir=/abrw/*) echo new; return 0 ;;
	esac
	case ",${ab_data_opts}," in
	*,ro,*) echo new; return 0 ;;
	esac
	echo legacy
}

# ab_mounted PATH [TYPE]: PATH is a mount point (of that type)
ab_mounted() {
	while read -r ab_dev ab_mp ab_type ab_opts ab_rest; do
		if [ "${ab_mp}" = "$1" ] && { [ -z "${2:-}" ] || [ "${ab_type}" = "$2" ]; }; then
			return 0
		fi
	done < "${AB_MOUNTS}"
	return 1
}

# ab_stick_data [WAIT]: waits up to WAIT seconds (default AB_STICK_WAIT) for the stick to be mounted at
# $AB_STICK, then prints $AB_STICK/System/Data (made when missing). Fails when there is no stick or it is
# not writable. Never falls back to a folder on the root: that would be tmpfs, and lost.
ab_stick_data() {
	ab_n="${1:-${AB_STICK_WAIT}}"
	while ! ab_mounted "${AB_STICK}"; do
		[ "${ab_n}" -gt 0 ] || return 1
		ab_n=$((ab_n - 1))
		sleep 1
	done
	mkdir -p "${AB_STICK}/System/Data" 2>/dev/null || return 1
	[ -w "${AB_STICK}/System/Data" ] || return 1
	echo "${AB_STICK}/System/Data"
}

# ab_copy SRC DST: a whole file or none (the stick is FAT: a pulled plug must not leave half a config)
ab_copy() {
	mkdir -p "$(dirname "$2")" || return 1
	cp "$1" "$2.tmp" && mv -f "$2.tmp" "$2" && return 0
	rm -f "$2.tmp"
	return 1
}

# --- WiFi: the master copy is System/Data/wifi/{wpa_supplicant.conf,ssid.cfg} ---------------------------------

# ab_wifi_in: new mode, once per boot: stick -> /etc. $AB_RUN/wifi-synced is made once the stick was seen
# (even if it holds no WiFi files yet); ab_wifi_out does nothing before that, so the shipped default can
# never overwrite the stick's master.
ab_wifi_in() {
	[ "$(ab_mode)" = new ] || return 0
	[ -e "${AB_RUN}/wifi-synced" ] && return 0
	ab_d="$(ab_stick_data)" || { ab_log "no stick: WiFi settings stay in RAM"; return 0; }
	if [ -s "${ab_d}/wifi/wpa_supplicant.conf" ]; then
		ab_copy "${ab_d}/wifi/wpa_supplicant.conf" "${AB_ETC}/wpa_supplicant.conf" &&
			chmod 600 "${AB_ETC}/wpa_supplicant.conf"
	fi
	if [ -s "${ab_d}/wifi/ssid.cfg" ]; then
		ab_copy "${ab_d}/wifi/ssid.cfg" "${AB_ETC}/autobleem/ssid.cfg"
	fi
	mkdir -p "${AB_RUN}" && : > "${AB_RUN}/wifi-synced"
}

# ab_wifi_out: new mode: /etc -> stick, for each file that changed
ab_wifi_out() {
	[ "$(ab_mode)" = new ] || return 0
	[ -e "${AB_RUN}/wifi-synced" ] || return 0
	ab_d="$(ab_stick_data 0)" || return 0
	for ab_f in wpa_supplicant.conf:wpa_supplicant.conf autobleem/ssid.cfg:ssid.cfg; do
		ab_src="${AB_ETC}/${ab_f%%:*}"
		ab_dst="${ab_d}/wifi/${ab_f#*:}"
		[ -s "${ab_src}" ] || continue
		cmp -s "${ab_src}" "${ab_dst}" 2>/dev/null && continue
		ab_copy "${ab_src}" "${ab_dst}" || ab_log "cannot save ${ab_src} to the stick"
	done
	return 0
}

# --- timezone: System/Data/timezone holds the zone name ---------------------------------------------------------

# ab_tz_ok NAME: a zone name that exists below the zoneinfo folder and cannot leave it
ab_tz_ok() {
	case "$1" in
	""|/*|*..*) return 1 ;;
	esac
	[ -f "${AB_ZONEINFO}/$1" ]
}

# ab_tz_in: new mode: replay the stored zone (what `settime tzone` does), at start
ab_tz_in() {
	[ "$(ab_mode)" = new ] || return 0
	ab_d="$(ab_stick_data)" || return 0
	[ -f "${ab_d}/timezone" ] || return 0
	read -r ab_z < "${ab_d}/timezone"
	ab_tz_ok "${ab_z}" || { ab_log "bad zone '${ab_z}' in ${ab_d}/timezone"; return 0; }
	rm -f "${AB_ETC}/localtime"
	ln -s "${AB_ZONEINFO}/${ab_z}" "${AB_ETC}/localtime"
	echo "${ab_z}" > "${AB_ETC}/timezone"
}

# ab_tz_save NAME: new mode: remember the zone `settime tzone` just set
ab_tz_save() {
	[ "$(ab_mode)" = new ] || return 0
	ab_d="$(ab_stick_data 0)" || { ab_log "no stick: the zone is lost at the reboot"; return 0; }
	echo "$1" > "${ab_d}/timezone.tmp" && mv -f "${ab_d}/timezone.tmp" "${ab_d}/timezone"
}

# --- Bluetooth: System/Data/bluetooth.img, ext4, loop-mounted over /var/lib/bluetooth ---------------------------

# ab_bt_img_make IMG: 4 MB, ext4 (the stock /sbin/mke2fs; mkfs.ext4 is the same program). Made under a
# temporary name and renamed, so a pulled plug never leaves a half image.
ab_bt_img_make() {
	ab_mk=""
	for ab_t in mke2fs mkfs.ext4; do
		command -v "${ab_t}" >/dev/null 2>&1 && { ab_mk="${ab_t}"; break; }
	done
	[ -n "${ab_mk}" ] || { ab_log "no mke2fs: no Bluetooth image"; return 1; }
	rm -f "$1.new"
	dd if=/dev/zero of="$1.new" bs=1024 count=$((AB_BT_IMG_MB * 1024)) 2>/dev/null &&
		"${ab_mk}" -t ext4 -F -q -L abbt "$1.new" >/dev/null 2>&1 &&
		mv -f "$1.new" "$1" && return 0
	rm -f "$1.new"
	ab_log "cannot make $1"
	return 1
}

# ab_bt_mount: new mode: loop-mount the image over $AB_BT_DIR (once). Without a stick or on any failure
# bluetoothd keeps its keys on tmpfs, as before. Legacy: the old bind mount of the overlay folder.
ab_bt_mount() {
	mkdir -p "${AB_BT_DIR}"
	if [ "$(ab_mode)" != new ]; then
		mount --bind /etc/bluetooth/bluetoothd "${AB_BT_DIR}"
		return 0
	fi
	ab_mounted "${AB_BT_DIR}" ext4 && return 0
	ab_d="$(ab_stick_data)" || { ab_log "no stick: pairings stay in RAM"; return 0; }
	ab_img="${ab_d}/bluetooth.img"
	[ -f "${ab_img}" ] || ab_bt_img_make "${ab_img}" || return 0
	if ! mount -t ext4 -o loop,noatime "${ab_img}" "${AB_BT_DIR}"; then
		# a pulled plug: let e2fsck repair it, then once more. Never recreate it - that would lose the pairings.
		command -v e2fsck >/dev/null 2>&1 && e2fsck -p "${ab_img}" >/dev/null 2>&1
		mount -t ext4 -o loop,noatime "${ab_img}" "${AB_BT_DIR}" ||
			ab_log "cannot mount ${ab_img}: pairings stay in RAM"
	fi
	return 0
}

# ab_bt_umount: new mode: flush and unmount the image (shutdown, and before the console suspends)
ab_bt_umount() {
	[ "$(ab_mode)" = new ] || return 0
	ab_mounted "${AB_BT_DIR}" ext4 || return 0
	sync
	umount -d "${AB_BT_DIR}" 2>/dev/null || umount -l "${AB_BT_DIR}"
}
