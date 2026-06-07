#!/bin/bash
# Build boot_package.fex for Orange Pi 4 Pro (A733) from source.
# Works on x86_64 AND arm64 Linux hosts (arm64 needs qemu-user-static for
# the x86-only Allwinner pack tools; statically linked, so plain
# `qemu-x86_64-static <tool>` works — no binfmt/root needed).
#
# Inputs (paths below assume the project oss/ checkouts):
#   UBOOT_SRC  = orangepi-xunlong/u-boot-orangepi, branch v2018.05-sun60iw2
#   PACK       = orangepi-build/external/packages/pack-uboot   (tools + blobs)
#
# What this replicates: orangepi-build's uboot_custom_postprocess() for
# BOARD=orangepi4pro / BOARDFAMILY=sun60iw2 (which upstream only runs on
# amd64 hosts).
set -euo pipefail
UBOOT_SRC="${UBOOT_SRC:?set UBOOT_SRC to u-boot-orangepi checkout}"
PACK="${PACK:?set PACK to orangepi-build/external/packages/pack-uboot}"
WORK="${WORK:-$(mktemp -d)}"
QEMU="${QEMU:-}"   # set to qemu-x86_64-static path on arm64 hosts; empty on x86_64

# ---- 1. compile vendor U-Boot (32-bit ARM, gcc-11-compatible flags) -------
cd "$UBOOT_SRC"
export CROSS_COMPILE=arm-linux-gnueabi-
export KCFLAGS="-fcommon -Wno-error -Wno-attributes -Wno-array-bounds -Wno-maybe-uninitialized"
make sun60iw2p1_t736_defconfig
# vendor tree ships an x86-only scripts/dtc/dtc; rebuild natively if needed
if ! ./scripts/dtc/dtc --version >/dev/null 2>&1; then
    rm -f scripts/dtc/dtc
    make -f scripts/Makefile.build obj=scripts/dtc srctree=. objtree="$(pwd)" \
         HOSTCC=cc HOSTCFLAGS="-O2 -fcommon" LEX=flex YACC=bison
fi
# ensure include/autoconf.mk exists (board-header configs -> make vars)
make CROSS_COMPILE=$CROSS_COMPILE include/config/auto.conf
make -j"$(nproc)" CROSS_COMPILE=$CROSS_COMPILE KCFLAGS="$KCFLAGS"
[[ -f u-boot.bin ]] || { echo "u-boot.bin missing"; exit 1; }

# ---- 2. pack boot_package.fex (mirrors uboot_custom_postprocess) ----------
cd "$WORK"
cp -r "$PACK/sun60iw2/bin/"* .
cp boot0_sdcard_a733.fex boot0_sdcard.fex
cp "$UBOOT_SRC/u-boot.bin" u-boot.fex
"$UBOOT_SRC/scripts/dtc/dtc" -p 2048 -W no-unit_address_vs_reg -@ -O dtb \
    -o orangepi4pro-u-boot.dtb -b 0 dts/u-boot-current.dts
cp sys_config/sys_config.fex sys_config.fex
sed -i 's/$/\r/' sys_config.fex                       # unix2dos
$QEMU "$PACK/tools/script"      sys_config.fex        # -> sys_config.bin
cp orangepi4pro-u-boot.dtb sunxi.fex
$QEMU "$PACK/tools/update_dtb"  sunxi.fex 4096
$QEMU "$PACK/tools/update_uboot" -no_merge u-boot.fex sys_config.bin
sed -i 's/$/\r/' boot_package.cfg
$QEMU "$PACK/tools/dragonsecboot" -pack boot_package.cfg

echo "OUTPUT: $WORK/boot_package.fex"; ls -la "$WORK/boot_package.fex"
