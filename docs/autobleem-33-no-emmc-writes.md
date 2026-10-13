# AUTOBLEEM-33 - stopping AutoBleem writing the eMMC (USRDATA) at runtime

Investigation only, 2026-10-13. Read-only: no code changed. Repo state: `psc-kernel-payload` develop `0bad209`,
submodule `sources/psc-kernel` at `7ff99d525`. Nothing was built or run on a console; where a number is an
estimate it says so.

## Summary

* The source of `initramfs/init` is **not anywhere** in the history. It is a 25 844-byte static ARM ELF built with
  GCC 9.2.0 (added 2020-03-23, `ad402601e`). Only the earlier busybox-shell version (`6863668a2`, 2020-03-16) is
  source. A replacement init is a small job (about 12 steps, listed in 1).
* **The binary already knows `data/autobleem/rootfs.squashfs`**, `/dev/loop-control`, `/dev/loop%i` and a second
  overlay string `lowerdir=squashfs:newroot,...`. So the 2020 design already had "squashfs on /data as an extra
  lower layer". This is a strings-level reading only (no disassembly done); it is worth testing, because it would
  let a prototype of the squashfs half run **without a new init**.
* The kernel has nearly everything variant A needs **built in**: squashfs (zlib, lzo, lz4, xz), loop, overlayfs,
  tmpfs, usb-storage, sd, both MediaTek USB host controllers, vfat, ext4. Missing: exFAT, NTFS (and zstd, which 4.4
  does not have anyway). So the stick must be **FAT32 or ext4**.
* **Recommendation: A**, with an init written from scratch. B does not meet the goal: Sony's whole userland has
  already run and written to /data before our rc, and it does not hold up for the early pieces (section 3).

## 1. Source of /init and what a replacement must do

Evidence:
* `sources/psc-kernel/initramfs/init`: `ELF 32-bit LSB executable, ARM, EABI5, statically linked, stripped`,
  `.comment` = `GCC: (GNU) 9.2.0`. Built into the kernel: `CONFIG_BLK_DEV_INITRD=y`,
  `CONFIG_INITRAMFS_SOURCE="initramfs"` (`board/psc/linux_autobleem_config:139-140`), so `boot.img` embeds it. The
  cmdline is `root=/dev/ram ... gpt` (line 534), but the binary ignores `root=` and hard-codes the partitions.
* History of the directory (`git log --all -S newroot`, `git log --all -- initramfs`): `96e0d4582 initramfs`,
  `8823de904 Update` (glibc-2.22 busybox), `6863668a2 Working initramfs - busybox mode` (2020-03-16: `init` is a
  busybox `sh` script, 80 lines), `ad402601e Bluetooth and wifi working + modules` (2020-03-23: the script moves to
  `initramfs/busybox init/init`, and `initramfs/init` becomes the 25 844-byte binary; `initnew` is the same file
  renamed). No `.c`/`.go`/`.rs` for it in any branch (`develop`, `feature/*`, `master`, `backup/*-2020` tags). I did
  not clone `autobleem2/autobleem` for it; the brief's repos were not needed to answer this, and a hit there would
  be a coincidence - please ask if you want that grep done.
* The shell version, `sources/psc-kernel/busybox init/init`, is the **readable ancestor** and the best spec. It
  does: mount devtmpfs, proc, sysfs, devpts, tmpfs on /dev/shm; `swmode idle; sleep 1; swmode device`; read `root=`
  from the cmdline; mount it ro (noatime); mount `/dev/mmcblk0p10` on `newroot/data` (`commit=1,noatime`);
  `mkdir data/autobleem/{rootfs,workdir}`; `mount -t overlay rootfs -o lowerdir=newroot,upperdir=...,workdir=...`
  over newroot; tmpfs on newroot/tmp; `mount --move` /dev /proc /sys; `exec switch_root /mnt/newroot /sbin/init`.

What the binary's strings add (`strings -a`): `devtmpfs`, `sysfs`, `shm`, `devpts`, `defaults,gid=5,mode=620`,
`mode=077`, `mnt`, `ext4`, `/dev/mmcblk0p7`, `/dev/mmcblk0p10`, `data/autobleem/rootfs.squashfs`,
`/dev/loop-control`, `/dev/loop%i`, `/dev/rootfs`, `autobleem`, `overlay`, the two `lowerdir=` strings, `newroot/data`,
`tmp`, `mnt/newroot/{dev,proc,sys,lib}`, `lib32`, `/mnt/newroot/bin/busybox.nosuid`, `switch_root`, `/dev/console`,
`/mnt/newroot`, `/sbin/init`, `/dev/null`.

Steps a replacement init must do (A, in order):
1. Mount devtmpfs on /dev, proc, sysfs; open /dev/console (stdio) - nothing works without these.
2. Mount root partition `/dev/mmcblk0p7` **read-only** (ext4) on `/mnt/newroot`. (This is the stock root, ROOTFS1.)
3. Rear port: if `/sys/module/musb_hdrc/parameters/charger_info` reads 3 (an OTG adapter is plugged - exactly the test
   `board/psc/overlay/bin/start_pman` and `usr/bin/start_pman:44-49` use), write `idle`, sleep, write `host` to
   `/sys/devices/platform/mt_usb/swmode`. **Order matters:** the driver accepts `host` only from the idle state and
   `device` and `host` exclude each other (`sources/psc-kernel/drivers/misc/mediatek/usb20/mt8167/usb20.c:1099-1129`,
   flags `device_mode`/`host_mode`). So the init must NOT write `device` as the 2020 script did. Without an adapter
   do not touch it (no host switch with nothing there).
4. Front ports need nothing: `CONFIG_MTK_USBFSH=y` (line 1632), host only.
5. Wait for a USB mass-storage block device (`/dev/sd*` appears by devtmpfs; `usb-storage`, `sd` are `=y`), poll with a
   timeout (suggest 6-10 s; USB enumeration plus a slow stick). On timeout: go to step 11 with no overlay = stock boot.
6. For each candidate partition (or the whole disk): mount ro (`vfat` or `ext4`, the only two that exist) on a scratch
   dir, look for the squashfs at a fixed path on the stick (suggest `/Autobleem/bin/abrootfs.squashfs`, next to the
   `start.sh` the stick already has).
7. Mount tmpfs on `/mnt/ab` with an explicit `size=` big enough for the file plus the upper layer; copy the
   squashfs onto it (`cp`, not a link; check the byte count against the stick's size), then **umount the stick**: from
   now on nothing depends on it, so a pulled stick or standby never reaches the root.
8. Attach `/dev/loopN` to the tmpfs copy (`/dev/loop-control` `LOOP_CTL_GET_FREE`, `LOOP_SET_FD`; `CONFIG_BLK_DEV_LOOP=y`)
   and `mount -t squashfs -o ro` on `/mnt/squashfs`. Verify a version marker file in it matches the booted kernel
   (modules `lib/modules/4.4.22`); if not, skip to 11 (a mismatched layer would break more than it fixes).
9. tmpfs on `/mnt/upper` with `upper` and `work` directories; `mount -t overlay overlay -o
   lowerdir=/mnt/squashfs:/mnt/newroot,upperdir=/mnt/upper/upper,workdir=/mnt/upper/work /mnt/overlay`. The first lower
   (leftmost) wins - the squashfs overrides the stock root, as the eMMC upper does today.
10. **Do not mount `mmcblk0p10`.** That is the change. But the stock system expects `/data` (a mount point for p10 and
    Sony's savedata/thermal state): mount p10 **read-only** at `/mnt/overlay/data`, or put a tmpfs there. Decide per
    service (section 4) - read-only is safest, nothing can write.
11. `tmpfs` on `/tmp` (the 2020 init did it), `mount --move` /dev /proc /sys into the new root, `exec switch_root
    /mnt/overlay /sbin/init`. On the stock path (no stick) the same sequence with `/mnt/newroot` and the stock p10 mount
    exactly as today.
12. Log to `/dev/console` and keep a copy in `/tmp/init.log` (the shell version did) - a prototype cannot be debugged
    without it; the rear port has no serial.

The shell version used glibc busybox in the initramfs (`busybox init/lib/*2.22*`, 650 kB). Writing a new init in C,
static (GCC 9 style toolchain from the console's `/opt/psc` gcc-6 also works), is simpler than a shell one and fits
`CONFIG_INITRAMFS_SOURCE`; a shell script needs a busybox and its libs in the initramfs (~650 kB + libc).

## 2. Kernel config (board/psc/linux_autobleem_config, psc-kernel tree)

Checked in `board/psc/linux_autobleem_config`; the fragments (`linux-common.fragment`, `linux-extra-wifi.fragment`)
do not touch these. (`grep` for `ZSTD|EXFAT` found nothing.)

| Need | Option | State | Line |
|---|---|---|---|
| squashfs | `CONFIG_SQUASHFS` | `=y` | 4140 |
| squashfs codecs | `SQUASHFS_ZLIB`, `SQUASHFS_LZ4`, `SQUASHFS_LZO`, `SQUASHFS_XZ` | all `=y` | 4147-4150 |
| xz decoder | `CONFIG_XZ_DEC=y` (+ARM BCJ `XZ_DEC_ARM=y`) | `=y` | 4623, 4627 |
| zstd | no `CONFIG_SQUASHFS_ZSTD` | **absent** (not in 4.4; needs 5.4+ backport) | - |
| squashfs decompressor | `SQUASHFS_DECOMP_SINGLE=y` | built in, single-threaded | 4143 |
| loop | `CONFIG_BLK_DEV_LOOP` | `=y`, 8 devices | 1300-1301 |
| overlayfs | `CONFIG_OVERLAY_FS` | `=y` | 4083 |
| tmpfs | `CONFIG_TMPFS=y`, `TMPFS_XATTR=y`, `TMPFS_POSIX_ACL=y` | `=y` | 4122-4124 |
| usb-storage | `CONFIG_USB_STORAGE` | `=y` | 3448 |
| SCSI disk | `CONFIG_BLK_DEV_SD` | `=y` | 1777 |
| rear (OTG) host | `CONFIG_USB_MTK_HDRC=y`, `USB_MTK_OTG=y`, `MTK_MUSB_SW_WITCH_MODE=y` | `=y` | 1637-1643 |
| front ports host | `CONFIG_MTK_USBFSH=y`, `MTK_MUSBFSH_QMU_SUPPORT=y` | `=y` | 1632, 1635 |
| generic hosts | `USB_XHCI_HCD`, `USB_EHCI_HCD`, `USB_OHCI_HCD`, mainline `USB_MUSB_HDRC` | not set (the MTK drivers replace them) | 3419-3426, 3471 |
| FAT | `FAT_FS=y`, `VFAT_FS=y`, `NLS_CODEPAGE_437=y`, `NLS_ISO8859_1=y`, `NLS_UTF8=y` | `=y` | 4106-4232 |
| ext4 | `CONFIG_EXT4_FS=y` | `=y` | 4047 |
| exFAT | none in 4.4 | **absent** | - |
| NTFS | `# CONFIG_NTFS_FS is not set` | **absent** (ntfs-3g/exfat-fuse are userland FUSE tools in the overlay only; `FUSE_FS=y`) | 4111, 4080 |
| devtmpfs | `DEVTMPFS=y`, `DEVTMPFS_MOUNT=y` | `=y` | 1151-1152 |
| modules | `MODULES=y`, `# MODULE_UNLOAD is not set` | **no module unload** | 249-251 |

What A needs that is missing:
* **exFAT/NTFS on the stick**: not available before the overlay exists, so the stick must be FAT32 or ext4. (Whether the
  AutoBleem sticks are FAT32, ext4 or exFAT in the field must be checked: the only evidence in this repo is that Sony's
  stock root has no exfat/ntfs tools - `reference/console-rootfs.txt` has only `mkfs.ext*`, `fusermount`.) If exFAT sticks
  are common, either a backported exFAT driver is needed (this is a kernel change), or the squashfs lives on a small
  FAT partition/file, or the stick gets a tiny extra FAT partition.
* A new `/init` (section 1). **Nothing else in the kernel config is missing** for A; no kernel rebuild is strictly needed
  except for the init itself (it is built into the kernel image via `INITRAMFS_SOURCE`, so a new `boot.img` is needed).
* `overlayfs` on 4.4: multi-lower (`a:b`) is supported (since 4.0). Upper on tmpfs: fine, **but** it needs
  `trusted.*` xattrs for opaque directories. `TMPFS_XATTR=y` is set; this was not verified on hardware. Test: `rm -r`
  then `mkdir` a directory that exists in the lower layer, on the overlay.
* Boot cmdline: the bootloader's cmdline (`CMDLINE_FROM_BOOTLOADER=y`, line 535) is ignored by the binary; leave it.
* 4.4 `squashfs` with `DECOMP_SINGLE`: reads are single-threaded, fine for a 20 MB image.

## 3. What must exist BEFORE the stick is up - and what breaks in B

Sources: `board/psc/overlay/**`, `board/psc/post-build.sh`, `board/psc/post-fakeroot.sh`, `scripts/overlay.py`,
`reference/abrootfs.files.txt`, `reference/console-rootfs.txt`.

The overlay is **not tiny**; `scripts/overlay.py` shapes it so it adds to the console and does not shadow it except
`ALLOWED_SHADOWS` (e.g. `bin/busybox`, `usr/bin/start_pman`, `lib/systemd/system/usbwatch.service`) and shared
libraries (newer glibc 2.34 etc.). What matters before the stick:

| Item | Path | When used | A | B |
|---|---|---|---|---|
| `usbwatch.service` (overlay copy; Sony `usb_watch` runs `/media/Autobleem/start.sh`) | `lib/systemd/system/usbwatch.service` | systemd boot, `After=powermanager.service` | in the squashfs, same as today | stock unit runs - fine, **it is how the stick starts** |
| `start_pman` (AutoBleem copy: host switch, `remount,rw /data`, `rm -f /data/syslog.log`, weston, `power_manage`) | `usr/bin/start_pman`, `bin/start_pman` | very early, from Sony's `powermanager.service` | replaced before systemd starts: **can drop every /data write** | **the stock one runs**: all its writes/remounts happen first |
| `udev` rules: module autoload `80-autobleem-modules.rules`, `81-autobleem-cd-pio.rules`, `99-autobleem-no-pointer.rules` | `etc/udev/rules.d/` | udev coldplug at sysinit | present | **missing at coldplug**; needs `udevadm control -R` and `trigger` after overlay; devices already plugged (e.g. the stick) never get the CD-PIO rule |
| Kernel modules `lib/modules/4.4.22` (pad drivers `hid-sony`..., WiFi, `btusb`, `sr_mod`, `cdrom`, `sg`, 107+ .ko, 8.2 MB in the 2020 file) + `modules.dep` (`depmod -a` in `etc/autobleem/modules`) | `lib/modules`, `lib/firmware` | udev autoload at device add; `insmod` from the stick | present; depmod can write to the tmpfs upper | **works only after the overlay**; `depmod -a` needs a writable `/lib/modules` (stock root is ro) so the overlay must cover `/lib` and is needed before any pad/BT/WiFi plug |
| Firmware | `lib/firmware` (6.8 MB in 2020; `board/psc/firmware-1.0`) | when a driver loads | present | after overlay only |
| bluetoothd + BlueZ libs (`usr/libexec/bluetooth/bluetoothd`, `bluetooth.service`, `abbtagent`, `/etc/bluetooth/{main,input}.conf`) | `usr/lib/systemd/system/bluetooth.service`, `etc/autobleem/bluetooth` | `autobleem.service` -> `systemctl restart bluetooth` | present | **must be started after the overlay**, which is the case today too, but D-Bus policy for BlueZ lives in `etc/dbus-1` -> D-Bus reload needed |
| glibc 2.34 + libs | `lib/libc-2.34.so`... (the 2020 one was 2.28, `lib/libc-2.28.so` 1.2 MB) | any overlay binary | present | the overlay's binaries run on the overlay's libc; Sony's processes keep their old mapped libc (open files stay valid). **A glibc swap under a running process is the dangerous part of B**: a process that execs after the overlay (e.g. Sony script that runs `/bin/ls`) gets the new libc with Sony's old dynamic loader/ABI expectations - normally fine (same soname, newer) but not tested |
| `dhclient.service`, `inetd.service`, `autobleem.service` | `lib/systemd/system/` + `.wants` links created by `post-build.sh` | systemd enables them at boot | present at boot | **not enabled** - systemd already built its transaction. Must be started with `systemctl daemon-reload` + `start` |
| `etc/systemd/journald.conf`, `system.conf` (volatile journal, defaults) | `etc/systemd/` | PID 1 read these at start | present | **ignored until restart**: journald writes where Sony configured it (possibly /data) |
| `etc/tmpfiles.d/tmp.conf` (no age limit on `/tmp`) | `etc/tmpfiles.d/` | `systemd-tmpfiles-clean.timer` after 15 min | present | picked up on next timer run; ok |
| `etc/shadow` (root password), `etc/hostname`, `etc/dhcpcd.conf`, `etc/resolv.conf` | `etc/` | login, network | present | present after overlay; `resolv.conf` is a Sony symlink? (check) |
| `/autobleem` marker, `etc/wpa_supplicant.conf` | root | AutoBleem | present | present after |

What breaks in B, in short:
1. **It does not fulfil the requirement.** Sony's boot has already run - weston, `power_manage`, Sony's own savedata/thermal
   services - and the stock `start_pman` has run `mount -o remount,rw /data`, `/` and `rm -f /data/syslog.log`. Even if our rc
   remounts `/data` read-only right after killsony, writes and the dirty journal happened before. And every Sony process
   keeps `/data` files open.
2. The overlay cannot be put on a running `/usr`, `/lib`, `/etc` without disturbing: an overlayfs mount over a directory
   hides the old mounts and open dirs (`cwd`) of existing processes; new `exec`s and `dlopen`s see the new files, running
   ones keep the old inodes. A Sony process that `dlopen`s a plugin from the new `/usr/lib` after the swap gets a mix.
   `lowerdir=<running dir>:<squashfs>` as proposed (the lower path is also the mount point) is usually accepted because the
   path is resolved before the mount, but I did not test it on 4.4; a bind mount of the old dir first is the safe form.
   Overlaying `/lib` is the riskiest: it holds the loader and libc that every running process maps.
3. `systemctl daemon-reload` + a reload of udev (`udevadm control -R`) is needed for the units/rules; a daemon-reload on
   Sony's PID 1 while `powermanager.service` runs is a new risk path (systemd 229).
4. Modules: any `insmod`/autoload before the overlay (CD drive, pad plugged at boot) has no modules - and no `sr_mod`.
5. `usbwatch.service` is stock but its `After=powermanager.service` race decides when `/media/Autobleem/start.sh` runs; B
   cannot change it without replacing the unit.

## 4. Runtime writes to /data today, and where each could live

`/data` = `/dev/mmcblk0p10`, mounted rw by `init`. The overlay's upper layer is `/data/autobleem/rootfs`, so **every write
to any path in the merged root (/etc, /var, /lib, /usr...) lands on the eMMC**, except tmpfs paths (`/tmp`, `/run`,
`/dev/shm`, `/var/volatile` if Sony mounts it). Found in the repo:

| Write | Evidence | Fix with upper on tmpfs (A) | Persist where |
|---|---|---|---|
| Bluetooth pairings, `/var/lib/bluetooth` bind-mounted from `/etc/bluetooth/bluetoothd` (BlueZ keys, a write on every pairing/connect) | `etc/autobleem/bluetooth:5-6`, `etc/autobleem/autobleem:4-7`, `post-build.sh:25-34` | goes to tmpfs: lost at reboot | a directory on the stick, bind-mounted over `/var/lib/bluetooth` by `etc/autobleem/bluetooth` (stick is vfat/ext4: BlueZ needs `chmod` and sets modes; **vfat cannot store modes/owners** -> use a loop-mounted ext4 image file on the stick, or sync a tarball at shutdown/on pairing) |
| WiFi: `/etc/wpa_supplicant.conf` (`update_config=1`: PSC-Bios "save" writes it), `/etc/autobleem/ssid.cfg` | `post-build.sh:70-74`, `install_payload.sh:9-12,25-28` | tmpfs: lost | stick (a config file, copied back into the upper at start; wpa_supplicant `update_config` writes in place, so bind-mount a stick file over it, or copy back on exit) |
| Timezone: `settime tzone` (`rm /etc/localtime; ln -s ...; echo > /etc/timezone`) | `board/psc/overlay/bin/settime:3-9` | tmpfs: lost | stick: a one-line file read by `start.sh`/an rc at each start, which calls `settime tzone` again (the clock has no battery - `hwclock -w` in `settime update`, see `70-autobleem-time`: that one writes the **RTC**, not the eMMC) |
| `dropbear -R` host key `etc/dropbear/` | `etc/autobleem/rndis:14-16` | tmpfs: new key each boot (ssh warnings) | stick |
| `depmod -a` (modules.dep) at `etc/autobleem/modules` | `etc/autobleem/modules:4-6` | tmpfs: fine, regenerate each boot (a second, ~1 s) or ship `modules.dep` in the squashfs and drop the `depmod` | squashfs |
| `mount -o remount,rw /` and `/data` in `start_pman` and `etc/autobleem/autobleem:4-5` ("ITS SAFE WE ARE IN OVERLAY") | `usr/bin/start_pman:51-53`, `autobleem:4-5` | remove; root stays ro, upper rw | n/a |
| `rm -f /data/syslog.log`, `systemctl disable syslog` (writes the unit symlink into `/etc` upper) | `start_pman:55-56` | tmpfs | n/a |
| `/data/thermal` config copy | `bin/start_pman:32-35` | write to tmpfs or skip | n/a |
| `/data/abbackup`, `abrootfs.tgz` rebuild | `bin/updaterootfs.sh` (dev tool, unused at runtime) | drop | n/a |
| Journal | `etc/systemd/journald.conf`: `Storage=volatile` | already RAM | - |
| Logs under `/var/log`, `/var/lib` (systemd timesync, random seed `/var/lib/systemd/random-seed`, `/var/lib/dhcpcd` leases - `persistent` in `etc/dhcpcd.conf`) | not enumerated in the repo | tmpfs | a lease is not worth persisting |
| Sony's own state: savedata, `/gaadata` (a separate mount point in the stock root, `reference/console-rootfs.txt:319`), `/data/thermal`, whatever stock PSC services write | not in this repo, no evidence | mount p10 **read-only** (or tmpfs) and look at what fails | unknown: **must be measured** with `inotifywait`/`mount` on a console, session by session (not done here) |

To find the real list on hardware: after boot, run `find /data -newer /tmp/boot-stamp` after a typical session; and
`cat /proc/self/mountinfo` for tmpfs paths. That could be prepared as a script; I did not run it (no console).

## 5. RAM: size of the overlay as a squashfs

Not measured: this laptop has no `mksquashfs`/`unsquashfs` (`command -v` finds `xz`, `zstd` only) and no copy of a
payload `abrootfs.tgz` (it is a build artefact, not in the repo). Estimates:
* The 2020 overlay `reference/abrootfs.manifest.txt` sums to **49.3 MB in 1 817 files** (computed from the listing: lib/modules
  8.2 MB, lib/firmware 6.8 MB, `bin/wpa_supplicant` 8.3 MB (static), `usr/share` 4.7 MB, `usr/lib` 3.2 MB, `usr/bin` 2.5 MB).
* Today's `abrootfs.tgz` is 19.5 MB (`CLAUDE.md` "Status"; the task says ~22 MB). The 107 modules + extra firmware grew it.
  Unpacked it is likely **55-70 MB** (estimate).
* squashfs sizes: `xz` is about the size of the `.tgz` or 15-25 % smaller, **~16-19 MB**; `lz4` (kernel has `SQUASHFS_LZ4`)
  ~ 1.5-1.8x larger, **~28-34 MB**; `zlib` ~ the tgz. Use `mksquashfs ... -comp xz -Xbcj arm -b 256K` (the kernel has
  `XZ_DEC_ARM=y`; use `-b 128K`/`256K`, not 1 MB: `SQUASHFS_FILE_CACHE`, fragment cache 3, `DECOMP_SINGLE`).
  I recommend measuring both on the build host (`psc-build`) and decompression time on the console: xz on a 1.1 GHz
  Cortex-A35 aarch32 is slower than lz4, but it only costs on first read of each file.
* tmpfs cost: the copy of the squashfs (16-34 MB) - **non-reclaimable** (tmpfs pages are not swapped here) - plus the
  upper layer (writes: pairing keys, `depmod` output ~ 0.5 MB, logs; set `size=` to cap it, e.g. 32 MB), plus squashfs's
  **decompressed page cache** (reclaimable) and a ~ 1 MB metadata cache. Total **~20-40 MB of the console's 1 GB RAM**
  (RAM size not stated anywhere in this repo; `vmalloc=496M` in the cmdline implies 1 GB). The loop device reads straight from
  the tmpfs file pages, so no second copy of the compressed data.
* Copy time: from a USB-2 stick at the 2.3-5 MB/s measured on the rear port (`docs/pad-drivers.md:75`) **4-8 s for xz,
  7-15 s for lz4**; front ports not measured. This lengthens every boot by that much. xz wins on RAM and boot time here.

## 6. Recommendation, risks, prototype

**Recommend A.** It is the only one that removes the eMMC from the data path from the first byte, because the overlay's
upper layer, `start_pman`, the udev rules and the units are all there before systemd starts. B is a late patch on a
running system: Sony's boot has already written, units are not enabled, the udev coldplug has run, and an overlay over a
live `/usr`/`/lib` is fragile.

Risks of A:
1. **No serial / recovery**: a faulty `/init` can hang before anything is on screen; an init bug is a brick (only a flash
   cable recovers it). Mitigation: stock-boot fallback on **every** error path (never `exit`/panic - fall through to the stock
   mount), a watchdog/timeout around each step, test on a spare console first.
2. **Boot-time stick dependency**: the stick must be in at power-on and recognised within the timeout, else stock boot (no
   AutoBleem). Rear-port stick on a hub did not enumerate in the owner's test (`docs/pad-drivers.md:68-82`); front ports
   are the dependable ones. Pull the stick during boot (before step 7 ends) -> stock boot.
3. **Rear port conflict**: host mode on the rear port is exclusive with the gadget (RNDIS/ssh) mode used by
   `etc/autobleem/rndis`. With a stick on the rear port there is no USB-network at that port. Front-port sticks leave the rear
   in device mode, but the init must then not switch the rear port at all (see step 3).
4. **Filesystem**: FAT32/ext4 only (exFAT/NTFS: no driver). FAT cannot hold the squashfs if > 4 GB (not an issue, 20-35 MB).
5. **Squashfs/boot.img/kernel version coupling**: the squashfs holds the modules `lib/modules/4.4.22` of the matching kernel
   build. A stick image with a different kernel build leaves module-load errors. Put a build-id marker in both; init compares
   (step 8).
6. **Integrity**: a corrupt copy -> a broken root. Check size + a CRC/sha of the squashfs against a sidecar file from the
   same directory before mounting.
7. **RAM**: 20-40 MB permanently gone; the PS1 emulator (`pcsx-abnxt`) is memory hungry - measure free memory in a session.
8. **tmpfs upper: xattrs** (opaque dirs) - unverified in 4.4 here. Test first.
9. **Sony's state**: with p10 read-only (or no p10) Sony services/games that write savedata fail or loop. AutoBleem itself does
   not need them, but PSC-Bios and the Sony menu (if the user goes back) might. This must be measured (section 4).
10. **Pairings and WiFi** must be moved to the stick (section 4) or the console forgets all pads every boot: this is a product
    change, not a plumbing one. FAT cannot keep BlueZ's modes: needs an ext4 image on the stick or a tarball.
11. **install_payload.sh/abflashkit**: the flash then writes only `boot.img` (BOOTIMG1), not `/data/autobleem/*`. One-time flash
    stays an eMMC write (outside runtime). `rm -rf /data/autobleem` in the old flow must not delete a console's old overlay by
    mistake - decide whether the stock-path (no stick) should still use the old `/data/autobleem/rootfs` (compat: drop
    it; "No stick = stock boot" says no).

### Prototype step list (smallest to largest)

0. **Free test, no code**: on a console flashed with today's payload, put an xz squashfs (built from the payload's abrootfs)
   at `/data/autobleem/rootfs.squashfs` and reboot. The existing binary's strings suggest it loop-mounts that file
   as a lower layer (`lowerdir=squashfs:newroot`). If it works, the squashfs half and its content are validated (modules,
   units, `ALLOWED_SHADOWS`) before any new init. (Still writes to /data until the init is replaced. Disassemble
   `initramfs/init` with `objdump -d` or a debugger to confirm the branch logic - not done here.)
1. Build host: `mksquashfs <abrootfs tree> rootfs.squashfs -comp xz -Xbcj arm -b 256K -noappend -all-root`; record the size and the
   sha256; add a build-id file inside and beside it.
2. Write the new `/init` in C (static, console gcc-6 `/opt/psc` toolchain), steps 1-12 above, with the stock-boot fallback
   everywhere and a console log; first version **without** the USB/stick part: loop-mount a squashfs from
   `/data/autobleem/rootfs.squashfs`, copy to tmpfs, tmpfs upper, **p10 ro**. Test on a spare console, serial-less: use the
   red/green LED (`/sys/class/leds/red/brightness` - the shell init had `redLed`) as a step indicator.
3. Add the rear-port host switch (charger_info == 3 test) and stick polling + vfat/ext4 mount + file copy.
4. Move the writers (section 4): `start_pman` without remounts; BT pairings/wifi/timezone to the stick; `depmod` at squashfs
   build time. Re-run `scripts/verify.sh`/`overlay.py check` for the new layout.
5. Measure: the list of writes to p10 over a real session (`find /data -newer`), free RAM, boot time with xz vs lz4,
   pull-the-stick-in-session and standby/resume.
6. Only then change `abflashkit`/`install_payload.sh` (the flash stops unpacking `abrootfs.tgz` to /data) and CI
   (`autobleem-console-tools` `build.yml` kernel-payload job) to ship `rootfs.squashfs` in the package.

### Open questions for the owner
* What filesystem do AutoBleem sticks have in the field (FAT32/exFAT/ext4)?
* Is the console's RAM 1 GB? (not stated in this repo.)
* May the stock path (no stick) keep working with `/data` writable, or is /data read-only always?
* Where should pairings live: an ext4 image file on the stick, or lost per boot?
