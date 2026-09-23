# Build guide

## Where it builds

Linux only (Buildroot). In practice: on **`psc-build`** inside the
`autobleem-kernel-build` Docker image. Buildroot refuses to run as root, so
`docker/run.sh` runs as the host uid:gid and persists the download + ccache
caches under `~/.cache/autobleem-kernel`.

```bash
# one-time image (adds Buildroot host deps to autobleem-build)
docker build -t autobleem-kernel-build -f docker/Dockerfile .

# full build of the faithful baseline
docker/run.sh scripts/build.sh all
ls output/images/psc-payload/kernel/
```

The kernel source is a submodule at `sources/psc-kernel`. On `psc-build` it is
cloned from the local bare mirror (no GitHub auth): `git clone
~/gitlab-mirror/screemer-psc-kernel.git sources/psc-kernel`. Elsewhere:
`git submodule update --init`.

## The two variants

| | `psc` (default) | `next` |
|---|---|---|
| purpose | conservative baseline | the improved image |
| Buildroot | 2022.02.x | 2024.02.x |
| BlueZ | ≈5.63 | ≈5.79 |
| WiFi drivers | your base kernel config | + `linux-extra-wifi.fragment` (ath9k_htc, carl9170, rtl8192cu) |
| firmware | shipped subset | full USB-WiFi set |
| dirs | `buildroot/`, `output/` | `buildroot-next/`, `output-next/` |

```bash
scripts/build.sh all             # psc
scripts/build.sh -V next all     # next
```

Both build the **same 4.4 kernel and the same hand-tuned kernel config**; `next`
only adds on top.

## Incremental & selective (fast loop)

Everything is cached per package.

```bash
scripts/build.sh kernel                 # rebuild ONLY the kernel + repack boot.img
scripts/build.sh bluez5_utils           # rebuild ONLY BlueZ + reassemble abrootfs.tgz
scripts/build.sh wpa_supplicant         # ...any Buildroot package by name
scripts/build.sh clean dropbear         # force a from-scratch rebuild of one package
scripts/build.sh assemble               # just repack the payload (no compiling)
scripts/build.sh -V next bluez5_utils   # per-variant
scripts/build.sh menuconfig             # then...
scripts/build.sh savedefconfig          # ...shrink back into the defconfig
scripts/build.sh verify                 # compare vs reference/
scripts/build.sh payload                # copy payload -> payload/<variant>/kernel
```

## Installing the result

Copy `output/images/psc-payload/kernel/` (or `output-next/...`) over
`autobleem2/autobleem-console-tools → payload/Apps/abflashkit/kernel/`, then flash via
`abflashkit`. **⚠ modifies console internal storage** — keep the `LBOOT.EPB`
recovery backup.

## Troubleshooting

- **`host-m4 1.4.18` (or other host pkg) fails to build** — an old Buildroot on a
  modern host. This is why the baseline is on 2022.02.x, not 2020.02. Don't go
  older than 2022.02 on Debian 12.
- **Kernel fails under gcc** — 4.4 vs a newer gcc. Add kernel patches (see
  `kernel-and-drivers.md`), don't bump the kernel (GPU pins it at 4.4).
- **Unknown config symbol dropped** — Buildroot silently drops unknown defconfig
  symbols. After `setup`, diff `configs/<variant>_defconfig` vs `output/.config`;
  fix names via `menuconfig` + `savedefconfig`. Symbol names differ between
  Buildroot versions (e.g. `exfat-utils`→`exfatprogs`, `pcre`→`pcre2`).
- **`mkimage`/`lz4` missing** — `post-image.sh` falls back to the system tools;
  the `autobleem-kernel-build` image provides `u-boot-tools` and `lz4`.
- **Clock skew "file in the future"** — the PC↔server clock offset; harmless.
  `touch` the tree if make loops on it.
