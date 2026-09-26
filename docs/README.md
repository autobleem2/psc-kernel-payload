# psc-kernel-payload — documentation

Deep reference for the AutoBleem PSC kernel + rootfs-overlay build. Quick start
is in the top-level `README.md`; developer context in `CLAUDE.md`.

- **[source-archaeology.md](source-archaeology.md)** — what the shipped payload
  contains, which archived GitLab repo builds each piece, the toolchain history,
  and how the overlay was originally assembled (by hand — no script existed).
- **[build-guide.md](build-guide.md)** — building, the two variants, the
  incremental/selective loop, and troubleshooting (Buildroot version choices,
  the kernel/GPU constraint, host-package pitfalls).
- **[kernel-and-drivers.md](kernel-and-drivers.md)** — the 4.4 kernel, the
  PowerVR GE8300 constraint that keeps it, the WiFi/Bluetooth driver set, and the
  roadmap for "more dongles / newer Bluetooth."
- **[userland-refresh.md](userland-refresh.md)**: the 2026-09-25 decision to stay on 4.4.
  More USB devices come from backports, a newer userland from the overlay. Covers the
  plan, what the kernel config allows, and the first inventory of the stock root.
- **[bt-pairing.md](bt-pairing.md)** — how the overlay's BlueZ stack is used by
  the PSC-Bios controller-pairing screen (the "feature in progress" UI), i.e.
  the consumer side of this Bluetooth stack.
