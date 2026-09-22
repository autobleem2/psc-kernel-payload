# Kernel and drivers

## The GPU pins the kernel at 4.4

The PSC is a MediaTek **MT8167** with an Imagination **PowerVR GX6250** (Rogue)
GPU. Its GLES/EGL driver is a **proprietary blob** built against the **4.4 kernel
ABI**. AutoBleem's launcher, PCSX and RetroArch all render through it (Weston +
EGL/GLES; the `PVR:` lines in the console logs). Mainline Linux has **no open
PowerVR Rogue driver**, so:

- A mainline 5.x/6.x kernel = **black screen** on real hardware (no GPU → no UI).
- The kernel is effectively **pinned to 4.4** (what the GPU blob supports).

Therefore "newer Linux" means: modernise the **4.4 BSP** (backport drivers, newer
userland), not bump the kernel major version. A newer MediaTek MT8167 BSP
(4.9/4.14) *might* be possible if a matching PowerVR blob can be sourced — a
research spike, deliberately **out of scope** for the shippable image.

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
- **Out-of-tree, TODO** (the big modern-chip win, NOT in the 4.4 tree): RTL8811/
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
