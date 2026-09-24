#!/usr/bin/env bash
#
# post-fakeroot.sh — the last touch before Buildroot tars the rootfs (BR2_ROOTFS_POST_FAKEROOT_SCRIPT): runs
# under fakeroot on the filesystem's own copy of the target, after the user and device tables (the syslog
# whiteouts, /etc/shadow's mode, and every package's own permission entries) are applied.
#
# The overlay is laid over the console's own root, so it ADDS tools and must not shadow the console's system:
# the 2020 overlay carried glibc, BlueZ, WiFi tools and AutoBleem's own units - never an init, D-Bus, udev or
# the console's /etc identity files. Buildroot's skeleton and the daemons BlueZ pulls in go here; the tools
# that link libdbus/libudev use the console's (stable sonames). scripts/verify.sh checks the result.
#
# Here and not in post-build.sh: the tables above map owners through etc/passwd + etc/group and set modes on
# package files (D-Bus's launch helper) - removed before them, the rootfs step failed both ways.
#
set -euo pipefail
TARGET_DIR="${1:?target dir}"
cd "${TARGET_DIR}"

rm -f  linuxrc init sbin/init lib32
rm -f  etc/passwd etc/passwd- etc/group etc/group- etc/fstab etc/hosts etc/os-release etc/profile \
       etc/nsswitch.conf etc/mtab etc/shells etc/issue etc/inittab usr/lib/os-release
rm -rf etc/profile.d etc/init.d etc/network
# D-Bus: the console's bus serves bluetoothd; keep only BlueZ's bus policy
rm -f  usr/bin/dbus-* usr/libexec/dbus-daemon-launch-helper lib/libdbus-1.so* usr/lib/libdbus-1.so*
rm -f  etc/dbus-1/system.conf etc/dbus-1/session.conf usr/share/dbus-1/system.conf usr/share/dbus-1/session.conf
# udev (eudev, built so hid2hci and BlueZ have libudev to link against): the console's systemd-udevd runs;
# keep only BlueZ's rule and helper
rm -f  sbin/udevd bin/udevadm sbin/udevadm usr/bin/udevadm lib/libudev.so* usr/lib/libudev.so* etc/udev/udev.conf
find lib/udev/rules.d usr/lib/udev/rules.d -type f ! -name '97-hid2hci.rules' -delete 2>/dev/null || true
rm -rf etc/udev/hwdb.d lib/udev/hwdb.d usr/lib/udev/hwdb.d

# Then everything else at a path the stock console has (reference/console-rootfs.txt): busybox's applet links
# over the console's bash, coreutils, util-linux, kmod and systemctl, udev helpers, /etc files - the lists
# above only ever named what somebody had thought of, and the first payload that booted put busybox over
# /bin/sh, tar and reboot (2026-09-24: AutoBleem no longer started). Libraries stay (newer builds of the
# same sonames), as do the few files the 2020 overlay replaced on purpose; the 2020 tool paths come back as
# links and /autobleem is created. scripts/overlay.py has the rule, and scripts/verify.sh checks it.
python3 "$(dirname "$(readlink -f "$0")")/../../scripts/overlay.py" shape --dir "${TARGET_DIR}"
exit 0
