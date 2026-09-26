#!/bin/bash

mount -o remount,rw /data

echo Installing AutoBleem payload
# What the user set up survives a flash: the WiFi (wpa_supplicant.conf, ssid.cfg) and the Bluetooth pairings
# (etc/bluetooth/bluetoothd, bind-mounted over /var/lib/bluetooth). Read through the running system's /etc,
# which is the overlay or the console's own root.
rm -rf /tmp/abkeep && mkdir -p /tmp/abkeep
[ -s /etc/wpa_supplicant.conf ] && cp -a /etc/wpa_supplicant.conf /tmp/abkeep/
[ -s /etc/autobleem/ssid.cfg ] && cp -a /etc/autobleem/ssid.cfg /tmp/abkeep/
[ -d /data/autobleem/rootfs/etc/bluetooth/bluetoothd ] && cp -a /data/autobleem/rootfs/etc/bluetooth/bluetoothd /tmp/abkeep/

rm -rf /data/autobleem
mkdir -p /data/autobleem/rootfs
mkdir -p /data/autobleem/workdir
# gunzip | tar, not tar -z: on a console flashed with the first Buildroot payload /bin/tar is a busybox
# without gzip, and this is what replaces that payload
gunzip -c /media/Apps/abflashkit/kernel/abrootfs.tgz | tar -xvf - -C /data/autobleem/rootfs

# Back into the NEW upper layer, never through /etc: while the payload runs, /etc is the overlay whose upper
# directory was just deleted, and a file written there is gone at the reboot - which is how every flash lost
# the WiFi (2026-09-26).
R=/data/autobleem/rootfs
[ -f /tmp/abkeep/wpa_supplicant.conf ] && cp -a /tmp/abkeep/wpa_supplicant.conf "$R/etc/wpa_supplicant.conf"
[ -f /tmp/abkeep/ssid.cfg ] && mkdir -p "$R/etc/autobleem" && cp -a /tmp/abkeep/ssid.cfg "$R/etc/autobleem/ssid.cfg"
if [ -d /tmp/abkeep/bluetoothd ]; then
	rm -rf "$R/etc/bluetooth/bluetoothd"
	mkdir -p "$R/etc/bluetooth"
	cp -a /tmp/abkeep/bluetoothd "$R/etc/bluetooth/bluetoothd"
fi
rm -rf /tmp/abkeep
sync
echo Done
