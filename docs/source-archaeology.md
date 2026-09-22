# Source archaeology — where the payload comes from

The abflashkit `kernel/` payload (shipped in `autobleem/AutoBleem2 →
payload/Apps/abflashkit/kernel/`) was, until this project, a set of **hand-assembled
static artefacts** with no build pipeline in the AutoBleem2 tree. This is the
reconstruction of how it was made, from the archived old-GitLab repos.

## What the payload contains

| File | Analysis |
|---|---|
| `boot.img` (6.8 MB) | U-Boot **FIT** image (magic `d00dfeed`). Description string: *"U-Boot fitImage for Yocto aud Baseline/4.4/aiv8167-rockman-emmc"* — a **Linux 4.4.22** kernel (LZ4) + device tree for the MediaTek **MT8167** ("aiv8167"/"rockman"). `dd`'d onto the `BOOTIMG1` partition. |
| `abrootfs.tgz` (22 MB) | The rootfs **overlay**, unpacked to `/data/autobleem/rootfs`. A **self-contained glibc 2.28** userland: BlueZ (`bluetoothd`, `libbluetooth.so.3.18.16`, `bluetoothctl`, `hciconfig`, `hid2hci`, **`sixaxis.so`** plugin), WiFi (`wpa_supplicant`, `iw`, `iwconfig`, dozens of wireless `.ko`), SSH (`dropbear`), `ntfs-3g` + exfat, `mc`, `nano`, `file`, busybox — plus the kernel's `/lib/modules/4.4.22` and `/lib/firmware`. AutoBleem-specific bits: `bin/abnet`, `bin/start_pman`, `bin/updaterootfs.sh`, `etc/autobleem/*`. |
| `boot.md5` | `164de8384db4256ee01ae95648372af4` (verified against the shipped boot.img). |
| `abrootfs.md5` | Stale (`35e5fd2b…` ≠ the shipped tgz `7704270c…`) — the flasher never checks it. |
| `recovery-{on,off}.img` | 16-byte MISC recovery flags. ON = command `2` at offset 8. |
| `install_payload.sh` | On-console: remount `/data` rw, preserve wpa/ssid, unpack `abrootfs.tgz` into `/data/autobleem/rootfs`. |

Version fingerprint of the overlay: glibc 2.28, glib 2.56.4, BlueZ 5.50
(`libbluetooth.so.3.18.16`), ncurses 6.1, readline 7/8, pcre 8.42, ntfs-3g .88,
openssl 1.0.0 — i.e. a **Buildroot ~2018.11–2019.02-era** rootfs. Critically it
is glibc **2.28**, NOT the console's Stretch/glibc-2.24 system libs — the overlay
is self-contained.

## The archived repos (github.com/autobleem, mirrored from gitlab.autobleem.tk)

| Repo | Builds | Notes |
|---|---|---|
| **psc-kernel** | `boot.img` | Linux 4.4.22 MT8167 fork. `.gitlab-ci.yml` used Docker image `screemer/psc-toolchain5` (crosstool `arm-unknown-linux-gnueabihf`, still on Docker Hub), `autobleem_defconfig`, then `uboot-support/{kernel.its,orig.dtb,packit.sh}` for the FIT (`lz4 -lf9` + 8-byte LE size + `mkimage`). No submodules; `rtl8188eu-master` is vendored. |
| **psc-bluez** | the Bluetooth stack | BlueZ 5.54 + the "DanTheMans" `plugins/sixaxis.c` patch (drops the SDP-record registration — the DualShock pairing fix). |
| **psc-rootfs** | userland extras | ONLY hand-built extras: wpa_supplicant, iw, libnl, openssl. Not the full rootfs. |
| **abflashkit** | the flasher app + payload | The 2020 tool. Its CI compiled the app and copied a **pre-assembled** `package/kernel/` — it never regenerated boot.img/abrootfs.tgz. |
| **psc-toolchain** | (the *app* toolchain) | `armv8-sony-linux-gnueabihf` GCC 8.2 — a DIFFERENT toolchain from the kernel's. |

## The gap this project fills

`abrootfs.tgz` had **no assembly script anywhere**. It was built by hand from:
kernel modules+firmware (psc-kernel CI `kernel_all.tgz`) + bluez output + the
psc-rootfs extras + busybox/dropbear/ntfs-3g/nano/mc + the `etc/` configs, then
`tar czf`. This project replaces that manual step with **one Buildroot external
tree** that rebuilds all of it from source (see `build-guide.md`).

## Toolchain history (why we don't reuse the old image)

The kernel CI used `docker.io/screemer/psc-toolchain5` (crosstool-ng
`arm-unknown-linux-gnueabihf`). It is still on Docker Hub, but this project does
**not** depend on it: Buildroot builds its own cross toolchain + glibc from
source, so the only host requirement is a generic build environment (our
`autobleem-build` image + `docker/Dockerfile`).
