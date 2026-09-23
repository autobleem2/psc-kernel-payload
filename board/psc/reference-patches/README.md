# board/psc/reference-patches — archived, NOT applied

Patches kept for reference / forward-porting, not wired into any build.

- `bluez5_utils/0001-danthemans-sixaxis.patch` — the archived AutoBleem
  "DanTheMans" DualShock/sixaxis fix against BlueZ **5.54** (from
  the archived psc-bluez repo). It drops the plugin's SDP-record registration.
  Both variants now build a NEWER BlueZ and use its upstream sixaxis plugin.
  If DualShock 3 pairing regresses on hardware, forward-port this to the new
  bluez version and drop it in `board/psc/patches-next/bluez5_utils/`.
