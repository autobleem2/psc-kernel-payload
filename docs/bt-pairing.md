# Bluetooth controller pairing (PSC-Bios integration)

This build provides the **Bluetooth stack**; the **UI to pair a controller** lives
in `autobleem/AutoBleem2 → apps/pscbios` (the PSC-Bios tool). Today PSC-Bios shows
a *"feature in progress"* screen for controller pairing; the goal is to make it
actually pair DualShock 4 (and other BT gamepads). This doc records what each side
must provide.

## What this build (the overlay) provides

Shipped in `abrootfs.tgz` (from the `bluez5_utils` package + kernel):

- `usr/libexec/bluetooth/bluetoothd` (+ `bluetooth.service`, `dbus-org.bluez.service`)
- `usr/bin/bluetoothctl`, `bin/hciconfig`, `bin/hid2hci`, `usr/bin/btmon`
- `usr/lib/bluetooth/plugins/sixaxis.so` — DualShock **3** USB-cable authorization
- kernel: `CONFIG_BT_HCIBTUSB` (BT USB dongles), `BT_HIDP`, `BT_RFCOMM`, `hci_uart`;
  the MT8167 has no built-in BT radio, so **a USB Bluetooth dongle is required**
  (or a combo WiFi/BT dongle).
- `etc/bluetooth/{main,input}.conf`, `etc/dbus-1/system.d/bluetooth.conf`

The newer BlueZ in the `next` variant improves modern-controller support out of
the box (DS4/DS5 HID over BT), which is the main reason to prefer it here.

## How pairing works per controller

- **DualShock 4 / DualSense / generic BT gamepad** — standard BT pairing:
  1. `bluetoothd` running, `hciconfig hci0 up`, `bluetoothctl` → `power on`,
     `agent on`, `scan on`.
  2. Put the pad in pairing mode (DS4: hold **Share + PS** until the light bar
     double-flashes).
  3. `pair <mac>` → `trust <mac>` → `connect <mac>`. It then reconnects on its own.
- **DualShock 3** — non-standard: plug it in over **USB**; the `sixaxis` BlueZ
  plugin authorizes it and writes the console's BT address to the pad, so it
  connects over BT afterwards. Needs the pad plugged in once + the plugin loaded.

## What PSC-Bios needs to do (the AutoBleem2 side — TODO)

In `apps/pscbios`, replace the "in progress" screen with a pairing flow that:

1. Ensures `bluetoothd` is up and `hci0` exists (a USB BT dongle is present) —
   otherwise show "plug in a Bluetooth adapter".
2. Starts a timed scan and lists discovered devices (name + type).
3. On select: `pair`/`trust`/`connect`; for a wired DS3, prompt to plug it in and
   let the sixaxis plugin do its thing.
4. Persists the pairing (BlueZ stores it under `/var/lib/bluetooth` — on the
   console this must be on writable storage, not the read-only overlay).

Drive it either by shelling out to `bluetoothctl`/`hciconfig` (simplest, matches
the ConsoleBackend/FakeBackend pattern the tool already uses) or via the BlueZ
**D-Bus** API (`org.bluez`). A dev-host `FakeBackend` returns canned devices so
the screen can be exercised on Windows through the DebugDriver.

**Storage caveat:** the overlay is unpacked read-only-ish to
`/data/autobleem/rootfs`; BlueZ's pairing DB (`/var/lib/bluetooth/<hci-mac>/...`)
must live somewhere writable that survives reboot. The shipped overlay even
contains a dev console's leftover `etc/bluetooth/bluetoothd/<MAC>/` pairing dirs —
those are stripped by `board/psc/post-build.sh`; real pairings are written at
runtime under `/var/lib/bluetooth`.

This is tracked in AutoBleem2, not built here — but the two land together: the
`next` overlay (newer BlueZ) + the PSC-Bios pairing screen.
