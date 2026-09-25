# Kernel and drivers

## The kernel stays at 4.4 (the owner's decision, 2026-09-25)

The PSC is a MediaTek **MT8167** with an Imagination **PowerVR GE8300** (Series 8XE, "Clark") GPU:
`rgx.fw.22.40.54.30` in the console's `/lib/firmware`, `CONFIG_MTK_GPU_VERSION="rgx clark 1.9ED"`. (These
docs said GX6250 until 2026-09-25; that is the MT8173's GPU.)

- **The userspace is a proprietary blob** (Mesa-based DDK 1.9: `libGLESv2_PVR_MESA.so`,
  `libpvr_dri_support.so`, its own `libgbm`/`libEGL`). AutoBleem's launcher, PCSX and RetroArch all render
  through it (Weston + EGL/GLES; the `PVR:` lines in the console logs).
- **Its kernel driver is source in our tree**: `drivers/misc/mediatek/gpu/gpu_rgx/m1.9ED*`.
  - The blob is tied to the DDK version, not to 4.4 as such, so a port to 4.19 or 5.10 would be possible.
  - That port is months of work, together with the MediaTek BSP's display, audio and power drivers.
- **Mainline has no usable driver for this GPU.**
  - The open PowerVR driver (6.8+) lists the GE8300 as unsupported.
  - A 6.x kernel means a black screen, or software rendering at best.

**Decided: no kernel bump.**
- The goal was more USB devices, and the modern dongles' in-tree drivers need 5.18 to 6.12, beyond any
  GPU-keeping kernel.
- They come from **backports and out-of-tree modules** on 4.4 instead.
- A newer userland comes from the overlay. See **[userland-refresh.md](userland-refresh.md)**.

## The kernel config is the owner's — treat it as sacred

`board/psc/linux_autobleem_config` is the full 124 KB `.config` the owner tuned by
hand in `menuconfig`. It already enables the complete Bluetooth stack (BR/EDR,
RFCOMM, BNEP, HIDP, LE; every HCI transport incl. BTUSB with BCM/RTL/Intel/QCA)
and a broad in-tree WiFi set (ath6kl, brcmfmac, cw1200, libertas, mt7601u,
mwifiex, p54, rsi, rt2x00 with all RT sub-chips, rtl8187, rtl8xxxu, zd1211, and
the staging r8188eu/r8712u/rtl8723au).

**Never regenerate or replace it.** The improved (`next`) variant only *adds* on
top, via `board/psc/linux-extra-wifi.fragment`
(`BR2_LINUX_KERNEL_CONFIG_FRAGMENT_FILES`), which Buildroot merges onto the base
config — it cannot turn anything off.

## WiFi dongle roadmap ("more dongles")

The base config is already broad, so the additive value is specific:

- **In-tree, done** (`linux-extra-wifi.fragment`): `ath9k_htc` (AR9271/AR7010 —
  the most common Linux USB WiFi, e.g. TL-WN722N v1), `carl9170` (AR9170),
  `rtl8192cu` (rtlwifi). Firmware added in `psc_next_defconfig` (`linux-firmware`).
- **Backports, TODO, first** (decided 2026-09-25): `CFG80211`/`MAC80211` are modules, so a backports
  release that supports 4.4 replaces the whole wireless stack and its drivers
  (mt76 among them). The plan is in [userland-refresh.md](userland-refresh.md).
  Bluetooth is built in (`BT=y`), so backports cannot reach it without a config change.
- **Out-of-tree, TODO**, for what backports on 4.4 lacks: RTL8811/
  8812/8821/88x2 and MT76x0/x2 (MT7610U/7612U). Add as **vendored driver trees +
  kernel patches** in `sources/psc-kernel`, exactly like the existing
  `rtl8188eu-master` / `drivers/staging/rtl8188eu`. Candidates:
  aircrack-ng/rtl8812au, morrownr/8821cu, morrownr/88x2bu, a mt76 backport. Each
  is its own commit in the kernel repo, built as a module, shipped in the
  overlay's `/lib/modules`.

## Bluetooth roadmap ("newer Bluetooth")

- Both variants now build a **newer BlueZ** than the shipped 5.50 (baseline via
  Buildroot 2022.02 ≈ 5.63; `next` via 2024.02 ≈ 5.79) and use its **upstream
  sixaxis plugin**.
- The archived 5.54 "DanTheMans" `sixaxis.c` patch is in
  `board/psc/reference-patches/` — **not applied**. If DualShock 3 pairing
  regresses on hardware, forward-port it into `board/psc/patches-next/bluez5_utils/`.
- Newer BlueZ brings better DualShock 4 / modern-controller support out of the
  box — which is what the PSC-Bios pairing screen needs (see `bt-pairing.md`).

## Building the kernel (inside this project)

Buildroot builds it as the `linux` package from `sources/psc-kernel` (via
`LINUX_OVERRIDE_SRCDIR`, so it compiles from the local checkout). The uncompressed
`arch/arm/boot/Image` is wrapped into the FIT `boot.img` by `board/psc/post-image.sh`
(identical flow to the old `uboot-support/packit.sh`). Fast loop:
`scripts/build.sh kernel`.

**Compiler note:** an old 4.4 kernel is happier with an older GCC. The baseline
uses Buildroot 2022.02 (gcc-11); if the kernel needs fixes under a newer gcc,
add kernel patches (in `sources/psc-kernel`, or a `board/psc/patches/linux/`
global patch dir) rather than bumping the kernel.
