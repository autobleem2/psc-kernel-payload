#!/usr/bin/env bash
#
# post-fakeroot.sh — the last touch before Buildroot tars the rootfs (BR2_ROOTFS_POST_FAKEROOT_SCRIPT): runs
# under fakeroot on the filesystem's own copy of the target, after the device table (the syslog whiteouts,
# /etc/shadow's mode) and the users tables are applied.
#
# /etc/passwd and /etc/group are the console's (the overlay must not replace them - see post-build.sh), but
# Buildroot needs them until here: the users/device tables map owners through them. So they go now, not in
# post-build.sh - removed there, the rootfs step failed ("cannot open file .../etc/group").
#
set -euo pipefail
TARGET_DIR="${1:?target dir}"
rm -f "${TARGET_DIR}/etc/passwd" "${TARGET_DIR}/etc/group" "${TARGET_DIR}/etc/passwd-" "${TARGET_DIR}/etc/group-"
exit 0
