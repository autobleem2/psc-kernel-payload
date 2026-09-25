# Staying on 4.4: backports and a newer userland overlay

**The owner's decision (2026-09-25):**
- The console keeps its **4.4 kernel**: `sources/psc-kernel`, the owner's config.
- More USB devices come from **backports** built as modules against that kernel.
- A newer userland comes from **refreshing the overlay**: scan the stock rootfs for what is outdated,
  build newer versions, and lay them over the console exactly as today (`overlay.py shape`/`check`).
- **No new root filesystem, no new kernel.**

## Why not a newer kernel

- **The GPU is what limits the kernel.**
  - The console's GPU is a PowerVR **GE8300** (Series 8XE, "Clark"), not a GX6250:
    `lib/firmware/rgx.fw.22.40.54.30`, and `CONFIG_MTK_GPU_VERSION="rgx clark 1.9ED"`.
  - Its kernel driver is source code in our tree: `drivers/misc/mediatek/gpu/gpu_rgx/m1.9ED*`, DDK 1.9.
  - The userspace blob is tied to that DDK version, so the driver could in theory be ported to a
    4.19 or 5.10 kernel, at months of work.
  - The mainline open PowerVR driver lists the GE8300 as unsupported, so on 6.x there is no usable GPU.
- **A GPU-keeping kernel would not bring the new drivers anyway.** The dongles people buy today have a
  good in-tree driver only from 5.18 to 6.12:

  | Driver | In-tree from |
  |---|---|
  | mt7921u | 5.18/5.19 |
  | rtw88 USB (RTL8821CU/8822BU) | 6.2, mature in 6.12 |
  | hid-playstation (DualSense) | 5.12 |
  | hid-nintendo (Switch pads) | 5.16 |

- **Backports carry a newer wireless stack onto an older kernel.**
  - backports-6.1 supports 4.14 to 6.1.
  - Older releases go down to 4.4.
- **The glibc version does not depend on the kernel.**
  - Current glibc still supports kernels from 3.2 up.
  - The overlay already ships its own glibc over the console's 2.24.

## What the kernel config allows

These are from `board/psc/linux_autobleem_config`. The config stays as it is: a fragment may only add.

| Stack | Config | Consequence |
|---|---|---|
| WiFi | `CFG80211=m`, `MAC80211=m` | **Backports can replace the whole wireless stack.** Their `cfg80211.ko`/`mac80211.ko` load instead of the tree's. |
| Bluetooth | `BT=y`, `BT_HCIBTUSB=y`, `BT_HIDP=y` | **Built in, so backports cannot replace it.** Getting a newer btusb would mean `BT=m`, a change to the owner's config. **Needs the owner's decision.** Until then, newer Bluetooth only comes from BlueZ and firmware in userland. |
| Pads | `HID=y`, `USB_HID=y`, `HID_SONY=y`, `JOYSTICK_XPAD=y` | A new HID driver (hid-playstation, hid-nintendo) can be added as an out-of-tree module on the built-in HID core. **A newer xpad cannot**: the built-in one binds first. |

## The plan

1. **Backports package.**
   - A `backports` package in this BR2_EXTERNAL: the newest backports release that still supports 4.4,
     built against `sources/psc-kernel`, WiFi only (`defconfig-wifi`).
   - Its modules go into the overlay's `/lib/modules/4.4.22/updates/`, ahead of the tree's.
   - Then remove what it supersedes from `linux-extra-wifi.fragment`. The config itself stays untouched.
2. **Out-of-tree Realtek drivers** for what backports on 4.4 lacks (RTL8821CU/8822BU/8812BU, then
   RTL8852BU/CU).
   - Source: morrownr's trees, made to build on 4.4, each its own commit in `psc-kernel`, as
     `rtl8188eu` is today.
3. **HID pads**: hid-playstation and hid-nintendo, forward-ported as out-of-tree modules. Also udev
   rules so AutoBleem's pad database sees them.
4. **The userland scan**: a `scripts/rootfs-versions.py` that lists what the stock root carries and
   at which version, next to what the overlay ships. The first pass, from `reference/console-rootfs.txt`'s
   library names, is below.
5. **The refreshed overlay** is `next` (Buildroot 2024.02.x) with the scan's picks.
   - **The rule stays as today**: a new *library* may shadow the console's library of the same soname;
     nothing else of the console's is replaced.
   - One addition, enforced by `overlay.py check`: **the graphics stack is never shadowed**. The PowerVR
     blob is a Mesa-based DDK build (`libGLESv2_PVR_MESA.so`, `libpvr_dri_support.so`) and was built
     against its own libraries:
     - `libEGL*`, `libGLES*`, `libgbm*`, `libglapi*`, `libdrm*`, `libpvr*`, `libPVR*`;
     - `libwayland-*`, and everything Weston 1.11 needs.
     A newer one there means a black screen.
6. **One supported-dongle list**: three or four cheap, current dongles (a RTL8821CU/8822BU, an MT7921AU
   if backports reaches it, a Bluetooth 5 dongle), tested on the console, and named in the manual.
   Every other chipset is best effort.

## The stock root, first pass (2026-09-25)

From the versioned library names in `reference/console-rootfs.txt` (Yocto, 2018). This is what the overlay
would lay a newer version over.

| Component | Stock | Notes |
|---|---|---|
| glibc | 2.24 | Already shadowed by the overlay's (2.28 in the 2020 payload). |
| libstdc++ | 6.0.22 (gcc 6) | Shadowing it is safe: newer is backward compatible. |
| systemd / libudev | libsystemd 0.14 (~v229-232), libudev 1.6.4 | PID 1 is the console's own. **Never shadow it.** |
| D-Bus | libdbus 3.14.7 (~1.10) | The console's daemon serves BlueZ. Keep it. |
| OpenSSL | 1.0.x (`libssl.so.1.0.0`) | A newer OpenSSL has another soname, so it installs alongside and shadows nothing. |
| ALSA | libasound 2.0.0 | |
| SDL2 | 2.0.4 (+ image/mixer/ttf) | Unused. The launcher brings 2.0.14 in `libs.tar.gz`. |
| Graphics | libdrm 2.4.x, libgbm/libEGL/libGLES (PVR Mesa), libwayland 1.12, Weston 1.11, pixman 0.34, cairo 1.14.6 | **Never shadow** (step 5). |
| Input | libinput 10.9.2 (~1.5), libevdev 1.x, mtdev, xkbcommon | Weston's. Keep them. |
| Filesystems | e2fsprogs libs, util-linux libblkid/libmount/libuuid, fuse 2.9.4 | |
| Other | zlib 1.2.8, bz2 1.0.6, lzma 5.2.2, expat 2.x, ffi 6, png 1.6.24, jpeg 62, tiff 5.2.5, freetype 2.6.x, fontconfig, ncurses 5.9, readline 5.2, pam, cap 2.25 | Safe candidates for a newer build, if a program of ours needs one. |

**The "program's libraries found in the merged root" check is not enough on its own.** A library can
load and still misbehave. Every shadowed library is a console boot test: AutoBleem 2 and 1.x start, Sony's
tools work, the standby works, and a game runs through pcsx-ab and RetroArch.
