#!/usr/bin/env bash
#
# post-build.sh — last touch-ups to TARGET_DIR before Buildroot makes the rootfs
# tar. Runs after every build; keep it idempotent.
#
# Buildroot calls this with $1 = $TARGET_DIR and exports BR2_EXTERNAL_PSC_PATH.
#
set -euo pipefail
TARGET_DIR="${1:-$TARGET_DIR}"

# The kernel is built separately (board/build-kernel.sh, gcc-6) into
# $(O)/kernel-stage; fold its modules into the rootfs before Buildroot tars it,
# so abrootfs.tgz carries /lib/modules/<ver> matching the flashed boot.img.
STAGE="${BASE_DIR:-}/kernel-stage"
if [ -d "${STAGE}/rootfs/lib/modules" ]; then
	echo "[post-build] merging kernel modules from ${STAGE}/rootfs/lib/modules"
	mkdir -p "${TARGET_DIR}/lib/modules"
	cp -a "${STAGE}/rootfs/lib/modules/." "${TARGET_DIR}/lib/modules/"
else
	echo "[post-build] WARNING: no kernel modules staged at ${STAGE} — run the kernel build first"
fi

# The AutoBleem overlay is layered on top of the console's own /data tree at
# runtime (install_payload.sh unpacks it to /data/autobleem/rootfs). Drop any
# stray per-console Bluetooth pairing state that must never ship in a release —
# the reference overlay carried the dev console's paired-device folders.
rm -rf "${TARGET_DIR}/etc/bluetooth/bluetoothd" 2>/dev/null || true

# Make sure the AutoBleem helper scripts are executable (overlay copies can lose
# the bit on a Windows checkout).
for f in bin/updaterootfs.sh bin/settime bin/ntpget bin/abnet bin/start_pman usr/bin/start_pman \
         sbin/dhclient-script etc/autobleem/bluetooth etc/autobleem/dhcp etc/autobleem/rndis; do
	[ -f "${TARGET_DIR}/${f}" ] && chmod +x "${TARGET_DIR}/${f}" || true
done

# The overlay is laid over the console's own root, so it ADDS tools and must not shadow the console's
# system: the 2020 overlay carried glibc, BlueZ, WiFi tools and AutoBleem's own units - never an init,
# D-Bus, udev or the console's /etc files. Buildroot's skeleton and the daemons BlueZ pulls in go; the
# tools that link libdbus/libudev use the console's (stable sonames). scripts/verify.sh checks the result.
cd "${TARGET_DIR}"
rm -f  linuxrc init sbin/init lib32
rm -f  etc/passwd etc/group etc/fstab etc/hosts etc/os-release etc/profile etc/nsswitch.conf etc/mtab \
       etc/shells etc/issue etc/inittab usr/lib/os-release
rm -rf etc/profile.d etc/init.d etc/network
# D-Bus: the console's bus serves bluetoothd; keep only BlueZ's bus policy
rm -f  usr/bin/dbus-* usr/libexec/dbus-daemon-launch-helper lib/libdbus-1.so* usr/lib/libdbus-1.so*
rm -f  etc/dbus-1/system.conf etc/dbus-1/session.conf usr/share/dbus-1/system.conf usr/share/dbus-1/session.conf
# udev (eudev, built so hid2hci and BlueZ have libudev to link against): the console's systemd-udevd
# runs; keep only BlueZ's rule and helper
rm -f  sbin/udevd bin/udevadm sbin/udevadm usr/bin/udevadm lib/libudev.so* usr/lib/libudev.so* etc/udev/udev.conf
find lib/udev/rules.d usr/lib/udev/rules.d -type f ! -name '97-hid2hci.rules' -delete 2>/dev/null || true
rm -rf etc/udev/hwdb.d lib/udev/hwdb.d usr/lib/udev/hwdb.d

# AutoBleem's units, enabled as the 2020 overlay enabled them (symlinks cannot live in a Windows checkout;
# the three syslog whiteouts are character devices - board/psc/device_table.txt)
mkdir -p etc/systemd/system/multi-user.target.wants etc/systemd/system/bluetooth.target.wants
ln -sfn /usr/lib/systemd/system/bluetooth.service etc/systemd/system/bluetooth.target.wants/bluetooth.service
ln -sfn /usr/lib/systemd/system/bluetooth.service etc/systemd/system/dbus-org.bluez.service
for u in autobleem dhclient inetd; do
	ln -sfn "/lib/systemd/system/${u}.service" "etc/systemd/system/multi-user.target.wants/${u}.service"
done

exit 0
