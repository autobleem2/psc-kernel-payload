# Bluetooth controller pairing (PSC-Bios integration)

This build provides the **Bluetooth stack**; the **UI to pair a controller** lives
in `autobleem2/autobleem-console-tools → apps/pscbios` (the PSC-Bios tool). PSC-Bios's *"feature in
progress"* screen is gone (DOCS-8: settling this doc's own staleness) — its **native backend** (BlueZ over
D-Bus, `apps/pscbios/docs/native-backend-plan.md`) now pairs for real, proven on the owner's console
2026-09-25/26 (the hub's `docs/todo.md` `TOOLS-1`/`KERNEL-1`: WiFi joined and saved across a reboot, a
DS4 paired and connected, abbtagent registered as the default agent again, the battery read). This doc
records what each side provides, and what is still left.

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

## What PSC-Bios does (the AutoBleem2 side) — done, leftovers still open

`apps/pscbios`'s native backend replaced the "in progress" screen with a pairing flow that:

1. Ensures `bluetoothd` is up and `hci0` exists (a USB BT dongle is present) —
   otherwise shows "plug in a Bluetooth adapter".
2. Starts a timed scan and lists discovered devices (name + type).
3. On select: `pair`/`trust`/`connect`; for a wired DS3, the sixaxis plugin does its thing once it is
   plugged in (abbtagent authorizes it — see `docs/pad-drivers.md`).
4. Persists the pairing (BlueZ stores it under `/var/lib/bluetooth` — on the
   console this is on writable storage, not the read-only overlay; see the storage caveat below).

It drives this via the BlueZ **D-Bus** API (`org.bluez`), not by shelling out to `bluetoothctl`/`hciconfig`
(the ConsoleBackend/NmBackend pattern the tool uses on the console; a dev-host `FakeBackend` returns canned
devices so the screen can be exercised on Windows through the DebugDriver).

**Left, per the hub's `docs/todo.md` `KERNEL-1`:** a wrong WiFi password, bluetoothd stopped or hung, and a
WiFi dongle not named `wlan0` — console-only checks, not yet run.

**Storage caveat:** the overlay is unpacked read-only-ish to
`/data/autobleem/rootfs`; BlueZ's pairing DB (`/var/lib/bluetooth/<hci-mac>/...`)
must live somewhere writable that survives reboot. The shipped overlay even
contains a dev console's leftover `etc/bluetooth/bluetoothd/<MAC>/` pairing dirs —
those are stripped by `board/psc/post-build.sh`; real pairings are written at
runtime under `/var/lib/bluetooth`.

The pairing flow itself is built and proven in AutoBleem2, not here — this repo only provides the
Bluetooth stack it runs against. The `next` overlay's newer BlueZ is what makes modern controllers (DS4/DS5
HID over BT) pair cleanly; the leftovers above land as further AutoBleem2 commits.
