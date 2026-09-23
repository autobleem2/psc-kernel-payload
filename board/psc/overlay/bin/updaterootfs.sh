#!/bin/bash

mkdir -p /data/abbackup
cp -r /etc/wpa_supplicant.conf /data/abbackup/
cp -r /etc/autobleem/ssid.cfg /data/abbackup/
rm -rf /etc/wpa_supplicant.conf
rm -rf /etc/autobleem/ssid.cfg



PWD=Â$(pwd)
rm -rf /media/abrootfs.tgz
cd /data/autobleem/rootfs
tar cvzf /media/abrootfs.tgz *
cd $PWD

mv /data/abbackup/ssid.cfg /etc/autobleem/ssid.cfg
mv /data/abbackup/wpa_supplicant.cfg /etc/wpa_supplicant.cfg

