# board/psc/patches-next — global patch dir for the `next` variant

`psc_next_defconfig` points `BR2_GLOBAL_PATCH_DIR` here. It is intentionally
empty of a bluez patch: `next` uses a newer BlueZ (Buildroot 2024.02.x) and
relies on upstream DualShock/sixaxis support rather than the 5.54-era
"DanTheMans" `sixaxis.c` patch used by the faithful baseline
(`board/psc/patches/bluez5_utils/`).

If DualShock 3 pairing regresses on hardware with the newer BlueZ, forward-port
that patch to the new bluez version and drop it in
`board/psc/patches-next/bluez5_utils/`.
