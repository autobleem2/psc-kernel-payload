# psc-kernel-payload

Reproducible, from-source build of the **AutoBleem PlayStation Classic kernel-flasher
payload** — the `kernel/` artefacts that `abflashkit` writes to the console:

| Artefact | What it is |
|---|---|
| `boot.img` | U-Boot **FIT image** = LZ4 Linux **4.4.22** kernel + device tree, for the PSC's MediaTek **MT8167** (aiv8167/rockman). `dd`'d onto the `BOOTIMG1` partition. |
| `abrootfs.tgz` | The AutoBleem **rootfs overlay** unpacked to `/data/autobleem/rootfs`: the **BlueZ** Bluetooth stack (+ DualShock `sixaxis` plugin), WiFi (`wpa_supplicant`, `iw`, wireless `.ko` modules), SSH (`dropbear`), `ntfs-3g`/exfat, `mc`, `nano`, busybox — a self-contained **glibc 2.28** userland plus the kernel's modules & firmware. |
| `boot.md5`, `abrootfs.md5`, `recovery-{on,off}.img`, `install_payload.sh` | flasher metadata + the on-console unpack script. |

This replaces the lost old-GitLab pipeline (which shipped these as hand-assembled
static artefacts) with **one Buildroot external tree** that rebuilds everything from
source, incrementally and selectively, in the AutoBleem Docker build image.

## What builds what

- **Kernel** → our own fork `autobleem/psc-kernel` (Linux 4.4.22, `board/psc/linux_autobleem_config`),
  built by Buildroot's `linux` package; `post-image.sh` wraps `Image` into the FIT `boot.img`
  exactly as the old `uboot-support/packit.sh` did (`lz4` + size trailer + `mkimage -f kernel.its`).
- **Userland** → ~20 **stock Buildroot** packages (`configs/psc_defconfig`), built from source
  against a Buildroot-built glibc toolchain — no external cross toolchain needed.
- **Bluetooth DualShock fix** → `board/psc/patches/bluez5_utils/` (the archived "DanTheMans"
  `sixaxis.c` patch), applied to Buildroot's `bluez5_utils` 5.54.
- **AutoBleem-specific files** (configs, systemd units, helper scripts, `abnet`) →
  `board/psc/overlay/` (the rootfs overlay).

The archived sources live under **github.com/autobleem** (`psc-kernel`, `psc-bluez`,
`psc-rootfs`, `abflashkit`) — mirrored from the old `gitlab.autobleem.tk`.

## Quick start (on the build server)

```bash
git clone --recurse-submodules git@github.com:autobleem/psc-kernel-payload.git
cd psc-kernel-payload

# one-time: extend the build image with Buildroot host deps (optional — the base
# autobleem-build image works too)
docker build -t autobleem-kernel-build -f docker/Dockerfile .

# full build (fetches + pins Buildroot, builds toolchain + kernel + userland,
# assembles the payload). First run is long; it is fully cached afterwards.
docker/run.sh scripts/build.sh all

# the payload:
ls output/images/psc-payload/kernel/
```

## Incremental & selective (the fast test loop)

Everything is cached per package, so you rebuild only what changed:

```bash
docker/run.sh scripts/build.sh kernel          # rebuild ONLY the kernel + repack boot.img
docker/run.sh scripts/build.sh bluez5_utils    # rebuild ONLY BlueZ + reassemble abrootfs.tgz
docker/run.sh scripts/build.sh wpa_supplicant  # ...any Buildroot package by name
docker/run.sh scripts/build.sh clean dropbear  # force a from-scratch rebuild of one package
docker/run.sh scripts/build.sh assemble        # just repack the payload (no compiling)
docker/run.sh scripts/build.sh menuconfig      # change the config...
docker/run.sh scripts/build.sh savedefconfig   # ...then shrink it back into configs/psc_defconfig
docker/run.sh scripts/build.sh verify          # compare the result against reference/
docker/run.sh scripts/build.sh payload         # copy the payload out to ./payload/kernel
```

Kernel hacking is the tightest loop: edit `sources/psc-kernel/`, then
`scripts/build.sh kernel` recompiles from that working tree (via `LINUX_OVERRIDE_SRCDIR`)
and repacks `boot.img` in seconds.

## Two variants: faithful vs improved

```bash
scripts/build.sh all               # faithful baseline (psc): 4.4 + BlueZ 5.54, matches today
scripts/build.sh -V next all       # improved image: newer BlueZ + userland, more WiFi dongles
scripts/build.sh -V next bluez5_utils   # ...selective, per variant
```

Both build the **same GPU-safe 4.4 kernel** and the **same hand-tuned kernel config**; `next`
only *adds* — newer userland (Buildroot 2024.02), and more in-tree USB-WiFi drivers
(ath9k_htc/carl9170/rtl8192cu) via a config fragment layered on top of your config, plus the full
firmware set. The kernel major version is pinned at 4.4 by the PowerVR GPU blob (no mainline
driver), so "newer" means a modernised 4.4 + newer userland, not a newer kernel. See `CLAUDE.md`.

## Installing a freshly built payload

Copy `output/images/psc-payload/kernel/` over
`autobleem/AutoBleem2 → payload/Apps/abflashkit/kernel/`, then build/flash through
`abflashkit` as usual. **⚠ Flashing modifies the console's internal storage** — always
keep the `LBOOT.EPB` recovery backup the flasher makes.

## Status

See `CLAUDE.md` for the developer context, the reference-vs-build differences, and the
remaining wiring (the AutoBleem overlay files, `abnet` source, firmware sets).

## Licence

The kernel is GPL-2.0 (Linux); BlueZ is GPL-2.0; Buildroot recipes are GPL-2.0. Per-component
upstream licences apply. AutoBleem-authored glue here is GPL-3.0-or-later, matching AutoBleem2.
