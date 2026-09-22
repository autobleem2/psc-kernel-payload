#!/usr/bin/env bash
#
# post-build.sh — last touch-ups to TARGET_DIR before Buildroot makes the rootfs
# tar. Runs after every build; keep it idempotent.
#
# Buildroot calls this with $1 = $TARGET_DIR and exports BR2_EXTERNAL_PSC_PATH.
#
set -euo pipefail
TARGET_DIR="${1:-$TARGET_DIR}"

# The AutoBleem overlay is layered on top of the console's own /data tree at
# runtime (install_payload.sh unpacks it to /data/autobleem/rootfs). Drop any
# stray per-console Bluetooth pairing state that must never ship in a release —
# the reference overlay carried the dev console's paired-device folders.
rm -rf "${TARGET_DIR}/etc/bluetooth/bluetoothd" 2>/dev/null || true

# Make sure the AutoBleem helper scripts are executable (overlay copies can lose
# the bit on a Windows checkout).
for f in bin/updaterootfs.sh bin/settime bin/ntpget sbin/dhclient-script; do
	[ -f "${TARGET_DIR}/${f}" ] && chmod +x "${TARGET_DIR}/${f}" || true
done

exit 0
