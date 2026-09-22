# psc-kernel-payload — developer context

A **Buildroot external tree** that rebuilds the AutoBleem PlayStation Classic kernel-flasher
payload from source: the `boot.img` (Linux 4.4.22 FIT for the MediaTek MT8167) and
`abrootfs.tgz` (the rootfs overlay — BlueZ+sixaxis, WiFi, dropbear, ntfs-3g, busybox, a
self-contained glibc-2.28 userland + kernel modules/firmware) that `abflashkit` writes to the
console. It replaces the lost old-GitLab pipeline, which shipped these as hand-assembled static
artefacts (there was **no** overlay-assembly script anywhere — abrootfs.tgz was built by hand).

Created 2026-09-22. Consumer: `autobleem/AutoBleem2 → payload/Apps/abflashkit/kernel/`
(and its `apps/abflashkit` tool — see that repo's `apps/abflashkit/CLAUDE.md`).

## Where the sources came from

Archived from the old `gitlab.autobleem.tk` (mirrored to **github.com/autobleem**, and bare in
`psc-build:~/gitlab-mirror/*.git`):

- **autobleem/psc-kernel** — Linux 4.4.22 fork for MT8167 ("Yocto aud Baseline/aiv8167-rockman").
  Old build: `.gitlab-ci.yml` used Docker image `screemer/psc-toolchain5` (crosstool
  `arm-unknown-linux-gnueabihf`, still on Docker Hub), `autobleem_defconfig`, then
  `uboot-support/{kernel.its,orig.dtb,packit.sh}` for the FIT. We now build it as Buildroot's
  `linux` package instead. `board/psc/{kernel.its,orig.dtb,linux_autobleem_config}` are copied
  from that repo (the config is the full expanded 4.4.22 `.config`).
- **autobleem/psc-bluez** — BlueZ 5.54 + the "DanTheMans" `plugins/sixaxis.c` patch (drops the
  SDP-record registration — the standard PSC DualShock pairing fix). Extracted to
  `board/psc/patches/bluez5_utils/0001-danthemans-sixaxis.patch`.
- **autobleem/psc-rootfs** — only the hand-built extras (wpa_supplicant, iw, libnl, openssl); all
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
- **Kernel**: Buildroot `linux` package, `CUSTOM_GIT` = autobleem/psc-kernel, custom config
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
5. **PSC-Bios controller pairing** (in `autobleem/AutoBleem2 → apps/pscbios`, NOT here): replace the
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

## Status (2026-09-22) — scaffold complete, not yet green

Done: the whole BR2_EXTERNAL scaffold; kernel.its/orig.dtb/linux config + sixaxis patch in place;
a first-pass `psc_defconfig` covering the ~20 overlay packages; post-image FIT + payload assembly;
build.sh/verify.sh; docker image extension; reference manifest.

**To do (each is real work, best done iterating on the server):**
1. `git submodule add` autobleem/psc-kernel at `sources/psc-kernel`, pin to the built commit.
2. First `build.sh setup && build.sh all`, then fix `psc_defconfig` symbol names against real
   Buildroot (`menuconfig` → `savedefconfig`). The draft config is best-effort; some symbol names
   (ncurses target libs, bluez sub-options, exfat, firmware sets) need validation.
3. Get the **kernel** building first and verify `boot.img` (FIT magic `d00dfeed`, `verify.sh`).
   Building 4.4.22 with Buildroot 2020.02's gcc-9 may need a few kernel patches (old kernels vs
   new host binutils/gcc) — collect them under `board/psc/patches/linux/` or the kernel repo.
4. Populate `board/psc/overlay/` from the reference overlay — the AutoBleem-custom files ONLY
   (`etc/autobleem/*`, systemd units, `bin/{abnet,start_pman,updaterootfs.sh,settime,ntpget}`,
   `sbin/dhclient-script`, `etc/bluetooth/{main,input}.conf`, `etc/dhcpcd.conf`). Do NOT ship the
   `etc/bluetooth/bluetoothd/<MAC>/` dirs (dev console pairing state) — post-build.sh also guards this.
   Extract on Linux (Windows tar mangles symlinks/modes). `abnet`/`start_pman` sources aren't in the
   archive yet — ship the prebuilt binaries in the overlay until located (check autobleem/AutoBleem2
   history and `root-autobleem.git`).
5. Firmware: enable the `linux-firmware` sets the shipped `/lib/firmware` carried (rtlwifi, mt7601u,
   ralink, brcm...) to match the wireless `.ko` set.
6. `verify.sh` will never show byte-identical tarballs (different build) — that's expected; the
   flasher checks `boot.md5` of ITS OWN boot.img, and never checks `abrootfs.md5`.

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
