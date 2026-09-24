#!/usr/bin/env python3
"""The AutoBleem overlay against the console it is laid over: shape it, and check it.

The overlay (abrootfs.tgz, unpacked to /data/autobleem/rootfs) is the upper layer of an overlayfs whose lower
layer is the console's own root. Whatever it carries at a path the console has REPLACES the console's file for
every program - Sony's init scripts, usb_watch, systemd, and AutoBleem 1.x and 2.x alike. The 2020 overlay
replaced almost nothing (glibc and a few files of AutoBleem's own); the first Buildroot overlay put busybox
over /bin/sh, tar, mount, reboot, modprobe, ... and AutoBleem stopped starting (2026-09-24: `source boot.sh`
not found - busybox's source searches only $PATH; `tar -z` refused; a busybox reboot that systemd ignores).

The rule, both here and in the check:
  * nothing at a path the stock console has (reference/console-rootfs.txt), except
      - shared libraries (lib/, usr/lib/: the same soname in a newer build - glibc, libstdc++, ...: the
        console's programs keep working on them, and the overlay's own programs need them), and
      - ALLOWED_SHADOWS - the files the 2020 overlay deliberately replaced;
  * every tool path the 2020 overlay had (reference/abrootfs.files.txt) still there - as a link to where
    Buildroot put that tool now - and the /autobleem marker AutoBleem looks for;
  * every program's libraries found in the merged root.

  overlay.py shape --dir TARGET_DIR          in board/psc/post-fakeroot.sh, before Buildroot tars the rootfs
  overlay.py shape --tar IN.tgz OUT.tgz      the same on a finished payload's abrootfs.tgz
  overlay.py check ABROOTFS.tgz              in scripts/verify.sh; exits 1 when the overlay is unsafe
"""
import io
import os
import re
import shutil
import struct
import sys
import tarfile

HERE = os.path.dirname(os.path.abspath(__file__))
REFERENCE = os.path.join(HERE, '..', 'reference')
CONSOLE_LIST = os.path.join(REFERENCE, 'console-rootfs.txt')
LIST_2020 = os.path.join(REFERENCE, 'abrootfs.files.txt')

# the console's files the 2020 overlay replaced on purpose, and keeps replacing
ALLOWED_SHADOWS = {
    'bin/busybox',  # the overlay's busybox; the console's own applets point at /bin/busybox.nosuid
    'usr/bin/start_pman',  # AutoBleem's power manager
    'lib/systemd/system/usbwatch.service',  # restarts usb_watch on failure
    'etc/systemd/journald.conf',
    'etc/systemd/system.conf',
    'etc/systemd/system/syslog.service',  # the three whiteouts: syslog off
    'etc/systemd/system/multi-user.target.wants/busybox-syslog.service',
    'etc/systemd/system/multi-user.target.wants/busybox-klogd.service',
    'etc/hostname',
    'etc/shadow',  # root's password
    'etc/resolv.conf',  # a file dhcpcd writes, where the console has a link into /run
}
LIBRARY = re.compile(r'^(usr/)?lib/[^/]+\.so(\.[0-9][0-9.]*)?$')
# taken out whatever the console has: Buildroot's /etc/dropbear is a link into /var/run, which does not exist
# at boot - the overlay's rndis script does `mkdir -p /etc/dropbear` and keeps the keys there (as in 2020)
ALWAYS_REMOVE = {'etc/dropbear'}
TOOL_DIRS = ('usr/sbin', 'usr/bin', 'sbin', 'bin', 'usr/libexec', 'libexec', 'lib/udev', 'usr/lib/udev')
MARKER = 'autobleem'  # AutoBleem's "the AutoBleem kernel is installed" (Env::autobleemKernel)
# a 2020 tool that goes by another name now
ALIASES = {
    'mount.ntfs': 'mount.ntfs-3g',  # ntfs-3g's own name for its mount helper
    'exfatfsck': 'fsck.exfat',  # exfat-utils -> exfatprogs
    'mkexfatfs': 'mkfs.exfat',
}
# 2020 paths that are not wanted back, and why
NOT_NEEDED_2020 = {
    'usr/bin/bccmd': 'removed from BlueZ itself (5.63 has none)',
    **{f'usr/bin/{t}': 'a build-time helper the 2020 overlay carried by accident - nothing on a console runs it'
       for t in ('gdbus-codegen', 'glib-compile-resources', 'glib-compile-schemas', 'glib-genmarshal',
                 'glib-gettextize', 'glib-mkenums', 'gobject-query', 'gtester', 'gtester-report',
                 'ncurses6-config', 'pcre-config')},
}


def load_console(path=CONSOLE_LIST):
    """{path: 'd' | 'f' | 'l:<target>'} of the stock console's root"""
    entries = {}
    with open(path, encoding='utf-8') as f:
        for line in f:
            if line.startswith('#') or not line.strip():
                continue
            parts = line.rstrip('\n').split('\t')
            entries[parts[1]] = 'l:' + parts[2] if parts[0] == 'l' else parts[0]
    return entries


def load_2020_tools(path=LIST_2020):
    """the tool paths (bin, sbin, usr/bin, usr/sbin) the 2020 overlay carried, and the marker"""
    tools = []
    with open(path, encoding='utf-8') as f:
        for line in f:
            p = line.rstrip('\n').split(' -> ')[0].strip().lstrip('./').rstrip('/')
            if p == MARKER or re.match(r'^(usr/)?s?bin/[^/]+$', p):
                tools.append(p)
    return tools


def allowed_shadow(path):
    return path in ALLOWED_SHADOWS or bool(LIBRARY.match(path))


def removals(overlay, console):
    """the overlay's entries to drop: at a path the console has (not allowed), or ALWAYS_REMOVE - with
    everything under a dropped directory"""
    drop = set()
    for p, kind in overlay.items():
        if p in ALWAYS_REMOVE:
            drop.add(p)
            continue
        c = console.get(p)
        if c is None or allowed_shadow(p):
            continue
        if kind == 'd' and c == 'd':
            continue  # directories merge
        drop.add(p)  # a file or link over anything, or a directory over a file or link
    for p in list(drop):
        if overlay.get(p) == 'd':
            drop.update(q for q in overlay if q.startswith(p + '/'))
    return drop


def is_applet(kind):
    return kind.startswith('l:') and kind[2:].rsplit('/', 1)[-1] == 'busybox'


def compat_links(full, kept, console, tools):
    """{2020 path: link target} for the 2020 tool paths the shaped overlay (`kept`) lacks: to where Buildroot
    put the tool, or - a busybox applet whose own link was dropped for shadowing the console's (blkid: the
    console has /sbin/blkid) - to busybox itself; plus the list of those with no counterpart. `full` is the
    overlay before the drop: an applet's link there says the applet is compiled in"""
    links, missing = {}, []
    for p in tools:
        if p == MARKER or p in kept or p in console or p in NOT_NEEDED_2020:
            continue
        name = p.rsplit('/', 1)[-1]
        target = None
        for n in (name, ALIASES.get(name)):
            if n is None:
                continue
            for d in TOOL_DIRS:
                q = f'{d}/{n}'
                if q == p or full.get(q, 'd') == 'd':
                    continue
                if q in kept:
                    target = q
                elif is_applet(full[q]) and kept.get('bin/busybox', 'd') != 'd':
                    target = 'bin/busybox'
                if target:
                    break
            if target:
                break
        if target is None:
            missing.append(p)
            continue
        links[p] = os.path.relpath(target, os.path.dirname(p) or '.')
    return links, missing


# --- the two forms of an overlay: a directory (post-fakeroot) and a tarball -----------------------------------
def dir_entries(root):
    entries = {}
    for base, dirs, files in os.walk(root):
        for name in dirs + files:
            path = os.path.join(base, name)
            rel = os.path.relpath(path, root).replace(os.sep, '/')
            if os.path.islink(path):
                entries[rel] = 'l:' + os.readlink(path)
            elif os.path.isdir(path):
                entries[rel] = 'd'
            else:
                entries[rel] = 'f'
    return entries


def norm(name):
    name = name[2:] if name.startswith('./') else name
    return name.rstrip('/')


def tar_entries(tar):
    entries = {}
    for m in tar.getmembers():
        n = norm(m.name)
        if not n or n == '.':
            continue
        entries[n] = 'd' if m.isdir() else ('l:' + m.linkname if m.issym() else 'f')
    return entries


def shape_plan(overlay, console, tools):
    drop = removals(overlay, console)
    kept = {p: k for p, k in overlay.items() if p not in drop}
    links, missing = compat_links(overlay, kept, console, tools)
    need_marker = MARKER not in kept
    return drop, links, missing, need_marker


def report_plan(drop, links, missing, need_marker, overlay, console):
    print(f'[overlay] {len(drop)} entries dropped (they would replace the console\'s own):')
    for p in sorted(drop):
        print(f'[overlay]   - {p}  (console: {console.get(p, "-")}, overlay: {overlay.get(p)})')
    for p, t in sorted(links.items()):
        print(f'[overlay]   + {p} -> {t}  (the 2020 path)')
    if need_marker:
        print(f'[overlay]   + /{MARKER}  (the AutoBleem kernel marker)')
    for p in missing:
        print(f'[overlay]   ! {p}: a 2020 tool with no counterpart in this build')


def shape_dir(root, console, tools):
    overlay = dir_entries(root)
    drop, links, missing, need_marker = shape_plan(overlay, console, tools)
    report_plan(drop, links, missing, need_marker, overlay, console)
    for p in sorted(drop, key=len, reverse=True):
        full = os.path.join(root, p)
        if os.path.islink(full) or not os.path.isdir(full):
            if os.path.lexists(full):
                os.remove(full)
        else:
            shutil.rmtree(full)
    for p, t in links.items():
        full = os.path.join(root, p)
        os.makedirs(os.path.dirname(full), exist_ok=True)
        os.symlink(t, full)
    if need_marker:
        with open(os.path.join(root, MARKER), 'w'):
            pass
        os.chmod(os.path.join(root, MARKER), 0o644)


def shape_tar(src, dst, console, tools):
    with tarfile.open(src, 'r:*') as tin:
        overlay = tar_entries(tin)
        drop, links, missing, need_marker = shape_plan(overlay, console, tools)
        report_plan(drop, links, missing, need_marker, overlay, console)
        with tarfile.open(dst, 'w:gz', format=tarfile.GNU_FORMAT) as tout:
            for m in tin.getmembers():
                if norm(m.name) in drop:
                    continue
                tout.addfile(m, tin.extractfile(m) if m.isreg() else None)
            for p, t in sorted(links.items()):
                info = tarfile.TarInfo('./' + p)
                info.type, info.linkname, info.mode = tarfile.SYMTYPE, t, 0o777
                tout.addfile(info)
            if need_marker:
                info = tarfile.TarInfo('./' + MARKER)
                info.mode, info.size = 0o644, 0
                tout.addfile(info, io.BytesIO(b''))


# --- the check ------------------------------------------------------------------------------------------------
def elf_needed(data):
    """DT_NEEDED of a 32-bit little-endian ELF (the console's), [] for anything else"""
    if data[:4] != b'\x7fELF' or data[4] != 1 or data[5] != 1:
        return []
    phoff, = struct.unpack_from('<I', data, 0x1C)
    phentsize, phnum = struct.unpack_from('<HH', data, 0x2A)
    loads, dynamic = [], None
    for i in range(phnum):
        ptype, off, vaddr, _, filesz = struct.unpack_from('<IIIII', data, phoff + i * phentsize)
        if ptype == 1:
            loads.append((vaddr, off, filesz))
        elif ptype == 2:
            dynamic = (off, filesz)
    if not dynamic:
        return []
    needed, strtab = [], None
    for i in range(0, dynamic[1], 8):
        tag, val = struct.unpack_from('<iI', data, dynamic[0] + i)
        if tag == 0:
            break
        if tag == 1:
            needed.append(val)
        elif tag == 5:
            strtab = val
    if strtab is None:
        return []
    base = next((off + strtab - vaddr for vaddr, off, size in loads if vaddr <= strtab < vaddr + size), None)
    if base is None:
        return []
    names = []
    for n in needed:
        end = data.index(b'\0', base + n)
        names.append(data[base + n:end].decode('ascii', 'replace'))
    return names


def check(tgz, console, tools):
    problems = []
    with tarfile.open(tgz, 'r:*') as tar:
        overlay = tar_entries(tar)
        bad = sorted(removals(overlay, console) - ALWAYS_REMOVE)
        bad += sorted(p for p in ALWAYS_REMOVE if p in overlay)
        for p in bad:
            problems.append(f'replaces the console\'s {p} (console: {console.get(p, "-")}, overlay: {overlay[p]})')
        for p in tools:
            if p not in overlay and p not in console and p not in NOT_NEEDED_2020:
                problems.append(f'the 2020 path /{p} is missing')
        lib_names = {p.rsplit('/', 1)[-1] for p in list(overlay) + list(console)
                     if re.match(r'^(usr/)?lib/[^/]+$', p)}
        elves = 0
        for m in tar.getmembers():
            if not m.isreg() or m.size < 64:
                continue
            f = tar.extractfile(m)
            head = f.read(4)
            if head != b'\x7fELF':
                continue
            elves += 1
            data = head + f.read()
            for soname in elf_needed(data):
                if soname not in lib_names:
                    problems.append(f'/{norm(m.name)} needs {soname}, which neither the overlay nor the console has')
    for p in problems:
        print(f'  [UNSAFE] {p}')
    if not problems:
        print(f'  [ok ] nothing of the console replaced beyond the 2020 set and libraries; every 2020 tool path '
              f'there; the libraries of all {elves} programs found')
    return 1 if problems else 0


def main(argv):
    console, tools = load_console(), load_2020_tools()
    if len(argv) >= 3 and argv[0] == 'shape' and argv[1] == '--dir':
        shape_dir(argv[2], console, tools)
        return 0
    if len(argv) >= 4 and argv[0] == 'shape' and argv[1] == '--tar':
        shape_tar(argv[2], argv[3], console, tools)
        return 0
    if len(argv) >= 2 and argv[0] == 'check':
        return check(argv[1], console, tools)
    print(__doc__)
    return 2


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
