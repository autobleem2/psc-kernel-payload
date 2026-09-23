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

# What of Buildroot's must NOT reach the console (its skeleton /etc, D-Bus and udev) is removed in
# post-fakeroot.sh, not here: Buildroot's user and device tables - packages add entries of their own, D-Bus
# its launch helper's permissions - are applied after this script and fail on a file that is gone.
cd "${TARGET_DIR}"

# AutoBleem's units, enabled as the 2020 overlay enabled them (symlinks cannot live in a Windows checkout;
# the three syslog whiteouts are character devices - board/psc/device_table.txt)
mkdir -p etc/systemd/system/multi-user.target.wants etc/systemd/system/bluetooth.target.wants
ln -sfn /usr/lib/systemd/system/bluetooth.service etc/systemd/system/bluetooth.target.wants/bluetooth.service
ln -sfn /usr/lib/systemd/system/bluetooth.service etc/systemd/system/dbus-org.bluez.service
for u in autobleem dhclient inetd; do
	ln -sfn "/lib/systemd/system/${u}.service" "etc/systemd/system/multi-user.target.wants/${u}.service"
done

exit 0
