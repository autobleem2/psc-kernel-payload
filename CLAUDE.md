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
0. **The overlay must only ADD to the console, never shadow it** (found 2026-09-23 on the first CI build,
   fixed the same day, unflashed). The first build had `BR2_INIT_SYSTEMD=y`, which forced merged /usr:
   `bin`/`lib`/`lib32`/`sbin` as symlinks into usr/ (laid over the console's root that hides its real /lib),
   its own systemd/udevd/init, Buildroot's /etc identity files (passwd, group, fstab, ...), its own D-Bus
   and udev daemons and libraries, and 16 systemd units enabled (networkd, resolved, timesyncd, ...). Now:
   `BR2_INIT_NONE` (no merged /usr), eudev only at build time, and `board/psc/post-build.sh` removes
   everything of the console's own system - the rule the 2020 overlay followed (glibc, BlueZ, tools,
   AutoBleem's units; the console's dbus/udev/libudev serve them). `scripts/verify.sh` fails the build on
   any symlinked top dir, init, shadowed system file or unit beyond the 2020 set - keep it that way.
   **That was not enough - flashed 2026-09-24, AutoBleem no longer started.** The kernel booted fine; the
   overlay still put 216 files over the console's own, 179 of them busybox applet links: `/bin/sh` (the
   console's is bash; busybox's `source boot.sh` searches only $PATH, so AutoBleem's `start.sh` died on its
   first line), `tar` (no gzip), `reboot`/`halt`/`poweroff` (the console's are systemctl; busybox's only
   signal init, and systemd ignores it), `mount`, `modprobe`, `insmod`, `login`, `env`, udev helpers, /etc
   files. It also lacked the `/autobleem` marker and the 2020 tool paths (`/bin/wpa_supplicant`,
   `/sbin/inetd`, ...), and its glibc is 2.34, not the 2.28 this file said. The rule is now checked against
   the console itself: `reference/console-rootfs.txt` is every path of the stock ROOTFS1
   (`scripts/console-rootfs-list.py`, from a vanilla rootfs.ext4); `scripts/overlay.py shape` (the last
   step of `post-fakeroot.sh`) drops everything at one of those paths except shared libraries and the few
   files the 2020 overlay replaced on purpose (`ALLOWED_SHADOWS`), puts the 2020 tool paths back as links
   (`ALIASES` for renamed tools, busybox for dropped applet links) and creates `/autobleem`;
   `overlay.py check` in `verify.sh` fails the build on any other shadow, a missing 2020 path (bar
   `NOT_NEEDED_2020`, each with its reason) or a program whose libraries the merged root lacks.
   `board/psc/busybox.fragment` brings back the 2020 applets the console lacks (tcpsvd, ftpd, telnetd,
   tftpd; tar -z), `BLUEZ5_UTILS_MONITOR` brings btmon, and `install_payload.sh` unpacks with `gunzip | tar`
   (a console carrying the bad overlay has a busybox tar without -z).
1. ~~Push the 3 kernel fixes to autobleem2/psc-kernel~~ - DONE 2026-09-23 (submodule pinned to them).
2. **`next` variant**: run `build.sh -V next all`; validate `psc_next_defconfig` symbols against
   Buildroot 2024.02 (exfatprogs/pcre2 already set) and the sixaxis-on-newer-bluez behaviour.
3. ~~**hciconfig/hid2hci** absent~~ — DONE: `BR2_PACKAGE_BLUEZ5_UTILS_TOOLS` +
   `..._TOOLS_HID2HCI` build them (`/usr/bin/hciconfig`, `/usr/lib/udev/hid2hci`, + hcitool/l2ping).
   (The PSC-Bios pairing flow drives `bluetoothctl`, which was already present, so this is for HID-mode
   dongles; `docs/bt-pairing.md`.)
4. ~~Populate `board/psc/overlay/`~~ - DONE 2026-09-23 from the shipped abrootfs.tgz: `etc/autobleem/*`,
   the units (`lib/systemd/system/{autobleem,dhclient,inetd,usbwatch}.service`,
   `usr/lib/systemd/system/bluetooth.service`; post-build.sh makes the `.wants` links, `device_table.txt`
   the three syslog whiteouts), `bin/{abnet,start_pman,updaterootfs.sh,settime,ntpget}`,
   `usr/bin/start_pman`, `sbin/dhclient-script`, `etc/bluetooth/{main,input}.conf`, `etc/dhcpcd.conf`,
   `etc/{hostname,inetd.conf,resolv.conf}`, `etc/systemd/{journald,system}.conf` (volatile journal).
   Left out on purpose: `etc/dropbear_key` (one private SSH host key shared by every console - `rndis` now
   makes a per-console key with `dropbear -R`), the dev console's `home/root` histories and Bluetooth
   pairings, `hwdb.bin`. `etc/shadow` is the 2020 file's accounts with root's password **`autobleem`** (the
   owner's choice, 2026-09-23; SHA-512 crypt - the old hash was MD5-crypt) for ssh/ftp over the USB network,
   mode 0600 through `device_table.txt` (the 2020 file was world-readable).
   `ntpget` is the one prebuilt binary (its source was never found).
5. ~~**Hardware test**~~ — DONE 2026-09-25/26 on the owner's console (`feature/pad-drivers`): boots, the
   launcher runs, modules load, DS3 (USB + cable pairing through abbtagent) and DS4 over Bluetooth work,
   WiFi (RT5370) joins, pairings survive a reboot. See "On the console" below.
6. Out-of-tree modern USB-WiFi drivers (8812au/8821cu/88x2bu/mt76) as vendored kernel trees (the big
   dongle win) — see `docs/kernel-and-drivers.md`.

## On the console (2026-09-25/26) - what the hardware taught, each now checked by `verify.sh`

- **Modules**: depmod must run (the image has kmod), the release is `4.4.22` (`LOCALVERSION=`), gcc-6's default
  PIE is off (`-fno-PIE`: GOT relocations 4.4 cannot load; `build-kernel.sh` rejects them), and
  `etc/udev/rules.d/80-autobleem-modules.rules` loads a module for a new device (the console has no such rule).
- **WiFi** joins only through dhcpcd's `10-wpa_supplicant` hook in `lib/dhcpcd/dhcpcd-hooks/` (post-build.sh).
  Buildroot's example `wpa_supplicant.conf` had no `update_config=1` (PSC-Bios's save failed) and an any-open-
  network entry: post-build.sh writes a plain one.
- **Pairings** persist through `etc/bluetooth/bluetoothd` (an empty dir, bind-mounted over /var/lib/bluetooth).
- **`install_payload.sh`** keeps the WiFi (`wpa_supplicant.conf`, `ssid.cfg`) and the pairings over a flash by
  writing them into the *new* `/data/autobleem/rootfs/etc` - never through `/etc`, which during the flash is the
  live overlay whose upper dir was just deleted (every flash lost the WiFi until 43aca25).
- **The clock**: no battery clock, every boot is 2018-09-01, and systemd 229's timesyncd never syncs (it waits
  for networkd, which the console does not run). `lib/dhcpcd/dhcpcd-hooks/70-autobleem-time` runs
  `settime update` (ntpget) at the first lease and touches `/run/autobleem/clock-set`. The time spent in a
  standby is not added to the clock either.
- **`/tmp` and the clock jump**: systemd's `tmp.conf` ages /tmp at 10 days, so once the clock jumps to today the
  daily `systemd-tmpfiles-clean` deleted everything boot put there (the launcher's `/tmp/lib`: ABFlashKit died on
  `Mix_LoadWAV`). `etc/tmpfiles.d/tmp.conf` overrides it without an age (the launcher's boot.sh adds an
  `x /tmp/*` rule in /run too, for older payloads).
- **Time zones**: `BR2_TARGET_TZ_INFO` (the zones are under `usr/share/zoneinfo/posix/`, regions linked to it);
  post-build.sh drops the `etc/localtime`/`etc/timezone` tzdata writes.
- **No pointer**: `etc/udev/rules.d/81-autobleem-no-pointer.rules` - a BCM2046 Bluetooth dongle's HID-proxy
  keyboard/mouse (0a5c:4502/4503) deauthorized, a DS4/DualSense touchpad's `ID_INPUT*` cleared; Weston drew
  its cursor otherwise. A real USB mouse is left alone.
- **The rear (OTG) port after a standby** does not come back on its own (MediaTek's musb does not restart its
  host session); the launcher's `rc/selection.sh` restarts it through `/sys/devices/platform/mt_usb/swmode`
  (AutoBleem2 f18583b). Unbind/bind of `musb-hdrc` leaves the port dead - its probe cannot run twice.
- The overlay's `rndis restart` (after every wake, and at boot) runs `dropbear -R`: a new SSH host key each time.

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
