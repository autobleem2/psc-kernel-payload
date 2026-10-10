# firmware-1.0 - the USB dongle firmware AutoBleem 1.0 shipped that linux-firmware (Buildroot) does not

`overlay/` is a second `BR2_ROOTFS_OVERLAY` of both defconfigs: its `lib/firmware` lands in `abrootfs.tgz` next to
what the `BR2_PACKAGE_LINUX_FIRMWARE_*` options install. The files are byte for byte the ones in the 1.0 payload's
`abrootfs.tgz` (autobleem-console-tools history, blob `25e051f5`, before TOOLS-3 removed the old payload).

| Files | For | Driver |
|---|---|---|
| `brcm/*.hcd` (114) | Broadcom USB Bluetooth (BCM20702 and relatives) | `btusb` + `btbcm` |
| `mediatek/mt7610u.bin` | MediaTek MT7610U USB Wi-Fi | none in 4.4 yet (mt76x0u) |
| `mediatek/mt7662u.bin`, `mt7662u_rom_patch.bin` | MediaTek MT7612U USB Wi-Fi | none in 4.4 yet (mt76x2u) |
| `rtlwifi/rtl8822bufw.bin` | Realtek RTL8822BU USB Wi-Fi | `88x2bu` (sources/rtl88x2bu) carries its own copy; kept for 1.0 parity |

The rest of the 1.0 set comes from Buildroot's linux-firmware instead: `rtl_bt/*` (`RTL_87XX_BT`, `RTL_88XX_BT`) and
`htc_7010.fw` (`ATHEROS_7010`). The 1.0 blobs for PCI/PCIe cards are left out - the console has no PCI.

The `.hcd` files are Broadcom's Bluetooth patch RAM files as Windows driver packages carry them; the MediaTek and
Realtek files are the vendors' redistributable firmware (linux-firmware's own licences, `LICENCE.mediatek`,
`LICENCE.rtlwifi_firmware.txt`).
