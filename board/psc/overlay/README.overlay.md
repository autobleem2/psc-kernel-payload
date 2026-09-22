# board/psc/overlay — the AutoBleem rootfs overlay

Everything under this directory (except this README) is copied verbatim onto the
Buildroot target rootfs (`BR2_ROOTFS_OVERLAY`) after the packages are installed,
and ends up in `abrootfs.tgz`.

Put ONLY AutoBleem-specific runtime files here — the stock package files come
from Buildroot. To populate it from the currently shipping overlay (on Linux,
where symlinks/modes survive):

    tar xzf .../AutoBleem2/payload/Apps/abflashkit/kernel/abrootfs.tgz -C /tmp/ref
    # then copy the AutoBleem-authored bits into this tree, e.g.:
    #   etc/autobleem/*                 (modules list, bluetooth, ssid.cfg)
    #   etc/bluetooth/main.conf input.conf
    #   etc/dhcpcd.conf
    #   bin/abnet start_pman updaterootfs.sh settime ntpget
    #   sbin/dhclient-script
    #   the AutoBleem systemd units

Do NOT copy:
  * stock package binaries/libs (Buildroot rebuilds them)
  * etc/bluetooth/bluetoothd/<MAC>/   (per-console pairing state; post-build.sh
    also removes it as a safety net)

See CLAUDE.md "To do" item 4.
