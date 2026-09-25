# Pad drivers, WiFi modules and cable pairing (2026-09-25)

What makes gamepads and USB WiFi sticks work on the flashed kernel, why each piece is there, and what is
still to be tested on a console. The owner's rules: the base kernel config (`board/psc/linux_autobleem_config`)
is never edited - everything below arrives through a fragment or the kernel tree; the owner's own 2020 patches
stay working.

## Why nothing loaded before

Three faults, each enough on its own - all three fixed:

| fault | effect | fix |
|---|---|---|
| no `depmod` in the build image (`modules_install` only warns) | no `modules.dep`/`modules.alias`: udev never loaded a module | `kmod` in `docker/Dockerfile`; `build-kernel.sh` fails without depmod or its output; `verify.sh` checks the tarball |
| the console's gcc-6 is built `--enable-default-pie`, 4.4.22 did not pass `-fno-PIE` | 100 of 107 modules carried `R_ARM_GOT_BREL`/`R_ARM_GOTPC` relocations 4.4's ARM loader rejects | psc-kernel `Makefile`: `-fno-PIE` for C and assembler (as 4.4.y stable later did); `build-kernel.sh` fails a build whose modules still carry one |
| release `4.4.22+` (setlocalversion's `+` for an untagged tree) | modules built for 2020's kernel (the libs pack's `xpad.ko`) refused for their version magic | `LOCALVERSION=` on every make: `4.4.22` as in 2020; `verify.sh` fails a `+` |

## The fragment - `board/psc/linux-common.fragment` (both variants)

Appended after the base config (a later assignment wins), so it also turns built-in drivers into modules:
a module is loaded only when its device appears, and can be replaced without a new boot.img.

- Pads: `HID_SONY`, `HID_PLAYSTATION`, `HID_NINTENDO`, `JOYSTICK_XPAD`, `HID_MICROSOFT` as modules (with their
  force-feedback options), plus the in-tree 4.4 drivers the base config left out: `HID_WIIMOTE`, `HID_BETOP_FF`,
  `HID_ACRUX`, `HID_EMS_FF`, Logitech/Thrustmaster/Zeroplus rumble, `HID_XINMO`, `HID_SAITEK`, and
  `HID_BATTERY_STRENGTH` (a Bluetooth pad's battery in `/sys/class/power_supply`).
- USB WiFi: `ATH9K_HTC`, `CARL9170`, `AR5523`, `RTL8192CU`, `VT6656` (the rest - rt2800usb, mt7601u, rtl8xxxu,
  r8188eu, r8712u, zd1211rw, ... - were already modules). `psc_defconfig` ships the Atheros firmware for them.
- `next` still adds `linux-extra-wifi.fragment` on top (now mostly the same options).

## The backported drivers - psc-kernel (Linux 6.1.y sources, 4.4 shims inside each file)

| driver | pads | notes |
|---|---|---|
| hid-sony | DS3 (and the SHANWAN clones), DS4 v1/v2, Sony DS4 USB adapter, Navigation, Motion, Buzz, Guitar Hero dongles, BD remotes | keeps the owner's patches: the SHANWAN step-3 skip (6.1's `SHANWAN_GAMEPAD`, same name match), DS4 v2 ids, the DS4 Bluetooth report with its CRC32 |
| hid-playstation | DualSense, DualSense Edge (USB, Bluetooth) | the lightbar is three plain LEDs (4.4 has no multicolor LED class) |
| hid-nintendo | Switch Pro, Joy-Con L/R, charging grip | LED writes go through a work item (4.4 has no blocking LED setter) |
| xpad | 249 Xbox/third-party USB pads (4.4 had 95), the 360 wireless receiver | |
| hid-microsoft | Xbox One S / Series / Elite 2 over Bluetooth (rumble), 8BitDo in Xbox mode | Bluetooth Xbox pads need ERTM off: `etc/autobleem/bluetooth` sets `disable_ertm` before bluetoothd starts |

`hid-core.c`'s `hid_have_special_driver` lists every id these drivers claim: 4.4 gives any device missing from
it to hid-generic first (how the DS4 v2 ended up there).

**SDL mappings change**: the 6.1 drivers follow the Linux gamepad layout and hid-sony/hid-nintendo set bit
0x8000 in the version, so the SDL GUIDs of these pads differ from before - the launcher's
`gamecontrollerdb.txt` needs lines for them (SDL 2.0.14 knows many of these layouts only through HIDAPI).
DS4/DualSense touchpads and motion sensors appear as extra input devices ("... Touchpad", "... Motion Sensors").

## Cable pairing - `package/abbtagent`

BlueZ's sixaxis plugin pairs a DS3 / Navigation / DS4 plugged in by USB, but first asks the default agent
(`AuthorizeService(device, HID)`); a console runs none, so the request failed and the pad was never paired
(the 2020 BlueZ patched the question away - the "DanTheMans" patch in `reference-patches/`). `abbtagent`
answers it instead, keeping BlueZ's authorization step:

- yes for the HID service of a Sony pad the plugin handles (Modalias `usb:v054Cp0268/042F/05C4/09CC`) while the
  device is not paired yet - the cable case;
- no to everything else, including over-the-air pairing requests (PSC-Bios pairs with its own agent, which is
  the default while it pairs);
- registers as the default agent (NoInputNoOutput), again whenever bluetoothd appears on the bus; logs every
  decision to the journal. Started with `bluetooth.target` (`verify.sh` allows that one unit link).

## USB power - where the stick and the dongles go

A USB WiFi stick draws a lot when its radio starts (the RT5370 declares 450 mA). On 2026-09-25 the AutoBleem
stick (200 mA), an RT5370 and a Bluetooth dongle (94 mA) shared one **bus-powered** hub on the rear port - ~750 mA
through a hub that has 500 mA to give - and the console "did not boot": the kernel and WiFi came up, but the
AutoBleem stick dropped off the bus, so usb_watch never found it and AutoBleem never started. With the stick on
a front port the same set booted every time. So: the AutoBleem stick on a front port; WiFi sticks on a front
port or a *powered* hub; a bus-powered hub only for low-draw devices (a Bluetooth dongle, a pad).

## To test on a console

1. `lsmod` shows modules loading: a WiFi stick of a listed chip gets its driver, `iw dev` lists it.
2. DS4 v2 over Bluetooth stays connected (the CRC fix), light bar and rumble work, battery in `/sys/class/power_supply`.
3. DS3 by USB: plug in, `journalctl -u abbtagent` says "HID authorized", unplug, PS button connects it.
4. A SHANWAN clone the same way.
5. DualSense, Switch Pro, an Xbox One S/Series pad over Bluetooth (pair in PSC-Bios); an Xbox pad by USB.
6. The launcher sees each pad with working buttons (the GUIDs above).
