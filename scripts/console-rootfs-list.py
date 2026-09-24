#!/usr/bin/env python3
"""Lists the stock console's root filesystem - every path, its kind and a symlink's target - for
reference/console-rootfs.txt, which scripts/overlay.py shapes and checks the overlay against: the overlay is
laid over this root, so anything it carries at one of these paths replaces the console's own.

The list is metadata only (paths, no file contents). Make it from a stock ROOTFS1 image, e.g. the rootfs.ext4
of an LBOOT.EPB backup (the vanilla one's md5 is ca710a128b7da4a23ace840c9d16e745, abflashkit's
LbootBackup::VanillaRootfsMd5):
    debugfs -R "rdump / rootfs" rootfs.ext4
    python3 scripts/console-rootfs-list.py rootfs > reference/console-rootfs.txt

Output: one line per entry, sorted - "d<TAB>path", "f<TAB>path" or "l<TAB>path<TAB>target" (paths relative
to /, no leading slash).
"""
import os
import sys


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    root = sys.argv[1]
    rows = []
    for base, dirs, files in os.walk(root):
        for name in dirs + files:
            path = os.path.join(base, name)
            rel = os.path.relpath(path, root).replace(os.sep, '/')
            if rel.startswith('lost+found'):
                continue
            if os.path.islink(path):
                rows.append(f'l\t{rel}\t{os.readlink(path)}')
            elif os.path.isdir(path):
                rows.append(f'd\t{rel}')
            else:
                rows.append(f'f\t{rel}')
    print('# the stock PlayStation Classic root (ROOTFS1, md5 ca710a128b7da4a23ace840c9d16e745) - '
          'scripts/console-rootfs-list.py')
    for row in sorted(rows, key=lambda r: r.split('\t')[1]):
        print(row)


if __name__ == '__main__':
    main()
