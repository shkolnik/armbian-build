# Orange Pi 4 Pro (A733) boot images — built from source, nothing committed

This directory contains **no binaries** — only `build-boot-package.sh`, which the
family's `build_custom_uboot()` runs at image-build time to produce the Allwinner
boot images:

| output | what it is |
|---|---|
| `boot0_sdcard.fex` | first-stage loader (SD/eMMC); carries the proprietary DRAM-init blob |
| `boot0_spinor.fex` | first-stage loader (SPI NOR) |
| `boot_package.fex` | packed container: **U-Boot (compiled here from source)** + TF-A monitor + SCP firmware |

## How it works

`build-boot-package.sh` clones two Orange Pi repos **at pinned commits** and
assembles everything on demand:

- **`orangepi-xunlong/u-boot-orangepi`** (branch `v2018.05-sun60iw2`) — U-Boot
  source, which the script **compiles** (AArch32, gcc-compat flags).
- **`orangepi-xunlong/orangepi-build`** (branch `next`) — sparse-checkout of
  `external/packages/pack-uboot/`, which provides the Allwinner pack tools
  (`dragonsecboot`, `script`, `update_uboot`, …) and the irreducible firmware
  blobs (`boot0_*.fex`, `monitor.fex` = TF-A BL31, `scp.fex` = E902 firmware,
  `sys_config`). These are proprietary / no-clean-source, so we never store them
  here — they come from the pinned upstream checkout.

Conceptually this is the equivalent of Radxa's prebuilt `u-boot-aw2501` .deb that
their Armbian family fetches — except Orange Pi publishes no such package, so we
clone their code and build/pack on demand instead.

## Why this shape

- **U-Boot is built from source**, never committed (the main reviewer objection to
  shipping a packed `boot_package.fex`).
- **No vendor binaries committed** to Armbian: the proprietary boot0/monitor/scp
  blobs and the x86-only pack tools all live in the pinned Orange Pi checkouts.
- **Reproducible**: pinned commit SHAs (`OPI_UBOOT_REF`, `OPI_BUILD_REF` in the
  script) — bump them deliberately to track upstream.

## Pins (update deliberately)

- `u-boot-orangepi`  @ `b791be842935b27268ae3d00e943a9075495f30a` (v2018.05-sun60iw2)
- `orangepi-build`   @ `7f776a209b72b92e8c6a06abc83b1e7597eef5af` (next)

Override at build time via env: `OPI_UBOOT_REF`, `OPI_BUILD_REF`, `UBOOT_DEFCONFIG`.

## Build-host requirements

The script runs on the Armbian build host (not in the rootfs chroot) and needs:
`git`, `gcc-arm-linux-gnueabi` (the vendor U-Boot is 32-bit ARM), a host C
compiler, `flex`/`bison`/`m4`, and — on non-x86_64 hosts — `qemu-user-static`
(the Allwinner pack tools are x86-only; run via `qemu-x86_64-static`). It also
needs network access to clone the pinned repos. The script checks for each and
exits with a clear "MISSING TOOL" message if absent.

## Write offsets (for reference)

`write_uboot_platform` (SD/eMMC): boot0 → byte 8192 (`bs=8k seek=1`),
boot_package → byte 16793600 (`bs=8k seek=2050`).
`write_uboot_platform_mtd` (SPI NOR): boot0_spinor → 0, boot_package → 262144.

## Manual run (debugging)

```bash
OUT=/tmp/opi4pro-boot ./build-boot-package.sh
```
