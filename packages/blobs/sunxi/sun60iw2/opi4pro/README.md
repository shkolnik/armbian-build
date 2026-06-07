# Orange Pi 4 Pro boot blobs

| file | origin | status |
|---|---|---|
| boot0_sdcard.fex | orangepi-build `external/packages/pack-uboot/sun60iw2/bin/boot0_sdcard_a733.fex` (branch next, rev 1.0.8) | included |
| boot0_spinor.fex | same dir, `boot0_spinor_a733.fex` | included |
| boot_package.fex | BUILT FROM SOURCE (2026-06-07): U-Boot compiled from orangepi-xunlong/u-boot-orangepi `v2018.05-sun60iw2` (defconfig sun60iw2p1_t736) + vendor monitor.fex/scp.fex blobs, packed with dragonsecboot per orangepi-build's flow. Reproduce with `build-boot-package.sh` (works on arm64 hosts via qemu-user-static). | included |

boot0 = Allwinner first-stage loader (DRAM training). boot_package = packed
container with vendor U-Boot 2018.05 + monitor (BL31) + scp (E902 firmware) + dtb.

## Producing boot_package.fex

Method A — extract from an official Orange Pi 4 Pro image (simplest, known-good pair):

    xz -dk Orangepi4pro_x.x.x_debian_..._linux6.6.xx.img.xz
    dd if=Orangepi4pro_....img of=boot_package.fex bs=512 skip=32800 count=16384

(16 MiB offset, 8 MiB copied — generous; the package is smaller and self-delimiting.)

Method B — build from source with orangepi-build (produces the same artifacts):

    cd orangepi-build && sudo ./build.sh   # U-boot package, board orangepi4pro
    # output: u-boot deb containing boot0_sdcard.fex + boot_package.fex

Write offsets used by write_uboot_platform (must match boot0 expectations):
boot0 → byte 8192 (bs=8k seek=1); boot_package → byte 16793600 (bs=8k seek=2050).
