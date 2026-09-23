# psc-kernel-payload — developer context

A **Buildroot external tree** that rebuilds the AutoBleem PlayStation Classic kernel-flasher
payload from source: the `boot.img` (Linux 4.4.22 FIT for the MediaTek MT8167) and
`abrootfs.tgz` (the rootfs overlay — BlueZ+sixaxis, WiFi, dropbear, ntfs-3g, busybox, a
self-contained glibc-2.28 userland + kernel modules/firmware) that `abflashkit` writes to the
console. It replaces the lost old-GitLab pipeline, which shipped these as hand-assembled static
artefacts (there was **no** overlay-assembly script anywhere — abrootfs.tgz was built by hand).

Created 2026-09-22. Consumer: `autobleem2/autobleem-console-tools → payload/Apps/abflashkit/kernel/`
(and its `apps/abflashkit` tool — see that repo's `apps/abflashkit/CLAUDE.md`).

## Where the sources came from

Archived from the old `gitlab.autobleem.tk` (mirrored to GitHub, and bare in `psc-build:~/gitlab-mirror/*.git`; the kernel is public as
**autobleem2/psc-kernel**, the rest are private archives under the owner's account `screemerpl`):

- **autobleem2/psc-kernel** — Linux 4.4.22 fork for MT8167 ("Yocto aud Baseline/aiv8167-rockman").
  Old build: `.gitlab-ci.yml` used Docker image `screemer/psc-toolchain5` (crosstool
  `arm-unknown-linux-gnueabihf`, still on Docker Hub), `autobleem_defconfig`, then
  `uboot-support/{kernel.its,orig.dtb,packit.sh}` for the FIT. We now build it as Buildroot's
  `linux` package instead. `board/psc/{kernel.its,orig.dtb,linux_autobleem_config}` are copied
  from that repo (the config is the full expanded 4.4.22 `.config`).
- **psc-bluez** (archived, `screemerpl/psc-bluez`) — BlueZ 5.54 + the "DanTheMans" `plugins/sixaxis.c` patch (drops the
  SDP-record registration — the standard PSC DualShock pairing fix). Extracted to
  `board/psc/patches/bluez5_utils/0001-danthemans-sixaxis.patch`.
- **psc-rootfs** (archived, `screemerpl/psc-rootfs`) — only the hand-built extras (wpa_supplicant, iw, libnl, openssl); all
  now come from stock Buildroot packages.
- **autobleem/abflashkit** — the original 2020 tool. Its CI just compiled the app and copied a
  pre-assembled `package/kernel/`; it never regenerated boot.img/abrootfs.tgz.

Full archaeology: AutoBleem2's memory note `psc-kernel-build-chain` and its `apps/abflashkit/CLAUDE.md`.

## Architecture

Buildroot (`BR2_EXTERNAL` = this repo) does everything from source in one tree:

- **Foundation = Buildroot 2020.02.12** (`BR_VERSION` in `scripts/build.sh`). Chosen because its
  `bluez5_utils` is **5.54** — matching `psc-bluez`, so the sixaxis patch applies cleanly — and its
  glibc 2.31 is era-close to the shipped **glibc 2.28**. The overlay ships its OWN glibc (it does
  NOT use the console's Stretch/glibc-2.24 system libs), which is why Buildroot (self-contained
  toolchain + rootfs) is the right tool rather than cross-building against the console sysroot.
- **Toolchain**: Buildroot-built glibc toolchain, `cortex_a7` + NEON-VFPv4 hardfloat (safe on the
  MT8167's Cortex-A35 running aarch32). Kernel headers = the in-tree 4.4.22 kernel's.
- **Kernel**: Buildroot `linux` package, `CUSTOM_GIT` = autobleem2/psc-kernel, custom config
  `board/psc/linux_autobleem_config`, image target `Image` (uncompressed). `build.sh` writes a
  `local.mk` with `LINUX_OVERRIDE_SRCDIR = sources/psc-kernel` so the kernel builds from the local
  submodule checkout (no private-repo fetch; instant `linux-rebuild`).
- **boot.img**: `board/psc/post-image.sh` — `lz4 -lf9 Image` + 8-byte LE size trailer +
  `mkimage -f kernel.its boot.img` (host uboot-tools + lz4). Identical flow to `uboot-support/packit.sh`.
  The FIT `signature` node needs **no key**: boot.img is dd'd straight to BOOTIMG1 (the exploit
  path); the console U-Boot does not verify it.
- **abrootfs.tgz**: Buildroot's `rootfs.tar.gz`, copied out by `post-image.sh`.
- **AutoBleem overlay**: `board/psc/overlay/` (`BR2_ROOTFS_OVERLAY`) — the AutoBleem-specific configs,
  systemd units, helper scripts and `abnet`. `post-build.sh` strips per-console BT pairing state.

Layout (BR2_EXTERNAL): `external.desc/mk`, `Config.in`, `configs/psc_defconfig`, `board/psc/`
(FIT + config + patches + overlay + post scripts), `scripts/` (build.sh, verify.sh), `docker/`,
`reference/` (ground-truth manifest of the shipped overlay), `sources/psc-kernel` (submodule).

## Two variants: faithful baseline + improved image

`build.sh -V <variant>` (or `VARIANT=`) selects one; they use separate Buildroot
checkouts and outputs so both coexist.

- **`psc`** (default) — the faithful 4.4 baseline: Buildroot 2020.02.12, BlueZ 5.54 + the
  archived DanTheMans sixaxis patch. `configs/psc_defconfig`, `buildroot/`, `output/`.
- **`next`** — the *improved* image (owner's ask, "safe wins on the 4.4 BSP"): Buildroot
  2024.02.x → newer BlueZ + userland; broader WiFi dongle support; full firmware set.
  `configs/psc_next_defconfig`, `buildroot-next/`, `output-next/`.

**The kernel is shared and the owner's hand-tuned menuconfig is sacred.** Both variants build
the SAME 4.4 kernel (`sources/psc-kernel`) with the SAME base config
(`board/psc/linux_autobleem_config` — the full 124 KB `.config` the owner built by hand, with the
complete BT stack and a broad in-tree WiFi set already enabled). `next` only *adds* on top, via a
Buildroot **config fragment** (`board/psc/linux-extra-wifi.fragment`,
`BR2_LINUX_KERNEL_CONFIG_FRAGMENT_FILES`) — it never turns anything off. The fragment enables the
in-tree USB-WiFi drivers the base config left off: **ath9k_htc** (AR9271/AR7010 — the most common
Linux USB WiFi, TL-WN722N v1), **carl9170** (AR9170), **rtl8192cu** (rtlwifi). `psc_next_defconfig`
adds the matching `linux-firmware` blobs.

The GPU pins the kernel to 4.4 (PowerVR GX6250 blob is 4.4-ABI; no mainline Rogue driver), so we
do NOT bump the kernel major version — see the plan below.

### Improvement plan (WiFi dongles / Bluetooth / userland)

1. **Newer BlueZ + userland** — free with Buildroot 2024.02.x in `next`. Validate the DualShock 3
   pairing on hardware; forward-port the sixaxis patch into `board/psc/patches-next/` if it regresses.
2. **In-tree dongle drivers** — done via `linux-extra-wifi.fragment` (ath9k_htc, carl9170, rtl8192cu).
3. **Out-of-tree modern USB WiFi** (the big win: RTL8811/8812/8821/88x2, MT76x0/x2) — NOT in the 4.4
   tree. Add as vendored driver trees + kernel patches under `sources/psc-kernel`, exactly like the
   existing `rtl8188eu-master`/`drivers/staging/rtl8188eu`. Candidates: aircrack-ng/rtl8812au,
   morrownr/8821cu, morrownr/88x2bu, mt76 backport. Each is its own commit in the kernel repo,
   built as a module and shipped in the overlay's `/lib/modules`. Tracked here; not started.
4. **exfatprogs** replaces the old exfat-utils in `next`; **pcre2** replaces pcre.
5. **PSC-Bios controller pairing** (in `autobleem2/autobleem-console-tools → apps/pscbios`, NOT here): replace the
   "feature in progress" screen with a real DS4/BT-gamepad pairing flow driving this overlay's
   `bluetoothctl`/`hciconfig`/`hid2hci` + the sixaxis plugin (DS3 over USB). The `next` overlay's
   newer BlueZ is what makes modern controllers pair cleanly. Full spec: `docs/bt-pairing.md`.

Full reference lives in **`docs/`** (source-archaeology, build-guide, kernel-and-drivers, bt-pairing).

## Build / incremental / selective

`docker/run.sh scripts/build.sh <cmd>` (Buildroot refuses root; run.sh runs as host uid:gid and
persists `dl/` + `ccache` under `~/.cache/autobleem-kernel`). Commands: `setup`, `all`, `kernel`,
`<pkg>` (bare Buildroot package name → `<pkg>-rebuild` + reassemble), `clean <pkg>`
(`-dirclean`), `reconfigure <pkg>`, `assemble` (repack payload only), `menuconfig`,
`savedefconfig` (shrink `.config` back into `configs/psc_defconfig` — **do this after every
menuconfig** so the diff stays reviewable), `linux-menuconfig`, `verify`, `payload`, `shell`.

Runs on Linux only (Buildroot). Author config/scripts anywhere; **build on `psc-build`**.

## Status (2026-09-22) — the `psc` baseline BUILDS end-to-end from source

**First full from-source build is green.** `docker/run.sh scripts/build.sh all` on `psc-build`
produces a complete, valid payload in `output/images/psc-payload/kernel/`:
- `boot.img` 7.2 MB, FIT magic `d00dfeed` (shipped was 6.8 MB — different build, expected)
- `abrootfs.tgz` 19.5 MB: **BlueZ 5.63** (`libbluetooth.so.3.19.6`, newer than the shipped 5.50) with
  `bluetoothd` + `sixaxis.so`, wpa_supplicant/iw, dropbear, ntfs-3g, exfatprogs, mc, nano, and
  **`lib/modules/4.4.22` — 107 `.ko` (91 WiFi)** freshly built.

**How it actually builds** (the architecture settled during the first build):
- Foundation is Buildroot **2022.02.x** (2020.02 host tools won't build on the Debian-12 host).
- The **kernel is decoupled**: `board/psc/build-kernel.sh` builds it with the console **gcc-6**
  (`/opt/psc`) — Buildroot's gcc-10 breaks the 4.4 fork's `__asmeq` register asserts. Buildroot
  builds the userland (gcc-10) and folds the staged modules in. The kernel fork got 3 commits to
  build under a modern host toolchain (still gcc-6 here, harmless): `-fcommon` for dtc,
  drop fork-added `-Werror` from ~27 subdir Makefiles, `log2.h` attribute fix. They are on
  autobleem2/psc-kernel `master` (pushed 2026-09-23), which `sources/psc-kernel` is a submodule of, so a
  fresh `--recurse-submodules` clone reproduces the build.
- FIT packaging needs the **system** `mkimage` (FIT-capable) + `dtc` (in the image); the `.its`
  signature node was dropped (unsigned; the console doesn't verify it).
- Docker image `autobleem-kernel-build` (docker/Dockerfile) now also carries `device-tree-compiler`.

**To do:**
0. **DO NOT FLASH the current output - the overlay is unsafe** (found 2026-09-23, the first CI build).
   `BR2_INIT_SYSTEMD=y` forces Buildroot's merged /usr, so abrootfs.tgz has `bin`, `lib`, `lib32`, `sbin`
   as SYMLINKS into usr/, and carries its own systemd, systemd-udevd and /usr/sbin/init. Laid over the
   console's root, the upper-layer `/lib` symlink hides the console's real /lib (systemd, firmware, Sony's
   libraries) and Buildroot's systemd would run as PID 1 - most likely a console that does not boot. The
   shipped overlay has real bin/lib/sbin directories and no init (glibc + tools only). Fix: `BR2_INIT_NONE`
   (which drops merged /usr), the few unit files it needs (bluetooth etc.) in `board/psc/overlay` - to-do 4.
   `scripts/verify.sh` now fails the build (and CI) on either, so no artifact is published until then.
1. ~~Push the 3 kernel fixes to autobleem2/psc-kernel~~ - DONE 2026-09-23 (submodule pinned to them).
2. **`next` variant**: run `build.sh -V next all`; validate `psc_next_defconfig` symbols against
   Buildroot 2024.02 (exfatprogs/pcre2 already set) and the sixaxis-on-newer-bluez behaviour.
3. ~~**hciconfig/hid2hci** absent~~ — DONE: `BR2_PACKAGE_BLUEZ5_UTILS_TOOLS` +
   `..._TOOLS_HID2HCI` build them (`/usr/bin/hciconfig`, `/usr/lib/udev/hid2hci`, + hcitool/l2ping).
   (The PSC-Bios pairing flow drives `bluetoothctl`, which was already present, so this is for HID-mode
   dongles; `docs/bt-pairing.md`.)
4. **Populate `board/psc/overlay/`** with the AutoBleem-custom files ONLY (`etc/autobleem/*`, systemd
   units, `bin/{abnet,start_pman,updaterootfs.sh,settime,ntpget}`, `etc/bluetooth/{main,input}.conf`,
   `etc/dhcpcd.conf`); NOT the `etc/bluetooth/bluetoothd/<MAC>/` dev pairing state (post-build.sh
   strips it). `abnet`/`start_pman` sources aren't in the archive — ship prebuilt until located.
   Note Buildroot's `/usr` layout (wpa_supplicant at `/usr/sbin`, etc.) vs the old merged `/bin`.
5. **Hardware test** — NOTHING here has booted on a console yet. The kernel is the same source +
   config, so it should, but it is unverified. Flash via abflashkit with an LBOOT.EPB backup ready.
6. Out-of-tree modern USB-WiFi drivers (8812au/8821cu/88x2bu/mt76) as vendored kernel trees (the big
   dongle win) — see `docs/kernel-and-drivers.md`.

## Gotchas

- **Everything builds on Linux.** Buildroot cannot run on Windows and refuses to run as root.
- The shipped overlay is **glibc 2.28** (`ld-2.28.so`), NOT the console's glibc 2.24 — the overlay
  is self-contained. Micro-version differences (glibc 2.31, glib 2.62, etc.) are harmless: binaries
  reference `/lib/ld-linux-armhf.so.3` (soname), and the flasher never checks `abrootfs.md5`.
- `boot.md5` in the reference is the SHIPPING boot.img's; a from-source kernel produces a different
  md5. That is fine — abflashkit writes and verifies its own boot.img/boot.md5 as a pair.
- Keep shell/cfg files **LF**. Reference version fingerprint: glibc 2.28, glib 2.56.4, BlueZ 5.50
  (libbluetooth.so.3.18.16) — note psc-bluez source is 5.54 — ncurses 6.1, readline 7/8, pcre 8.42,
  ntfs-3g .88, openssl 1.0.0.
