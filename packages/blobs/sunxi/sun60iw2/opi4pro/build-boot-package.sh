#!/bin/bash
#
# Build the Orange Pi 4 Pro (Allwinner A733 / sun60iw2) boot images entirely from
# Orange Pi's published sources, at pinned commits. NOTHING binary is committed to
# Armbian — this script clones the two upstream Orange Pi repos at build time and
# produces:
#   boot0_sdcard.fex   - first-stage loader (SD/eMMC),   contains proprietary DRAM init
#   boot0_spinor.fex   - first-stage loader (SPI NOR)
#   boot_package.fex   - packed { U-Boot (built here from source) + TF-A monitor + SCP fw }
#
# Conceptually this is the equivalent of Radxa's prebuilt u-boot .deb that Armbian
# fetches — except Orange Pi publishes no such package, so we clone their code and
# assemble on demand. The only irreducible proprietary bits (boot0 DRAM blob, SCP
# firmware, TF-A monitor, and the x86-only Allwinner pack tools) all come from the
# pinned Orange Pi checkouts; we never store them in this repo.
#
# Runs on x86_64 and arm64 build hosts. The Allwinner pack tools are x86-only ELF
# binaries; on arm64 they are executed via qemu-x86_64-static (statically linked,
# so no binfmt/root needed).
#
# Usage:  OUT=/path/to/output/dir  ./build-boot-package.sh
#         (OUT defaults to the current directory)
#
set -euo pipefail

# --- Pinned upstream sources (override via env to bump) ----------------------
OPI_UBOOT_REPO="${OPI_UBOOT_REPO:-https://github.com/orangepi-xunlong/u-boot-orangepi.git}"
OPI_UBOOT_REF="${OPI_UBOOT_REF:-b791be842935b27268ae3d00e943a9075495f30a}"   # branch v2018.05-sun60iw2
OPI_BUILD_REPO="${OPI_BUILD_REPO:-https://github.com/orangepi-xunlong/orangepi-build.git}"
OPI_BUILD_REF="${OPI_BUILD_REF:-7f776a209b72b92e8c6a06abc83b1e7597eef5af}"   # branch next
UBOOT_DEFCONFIG="${UBOOT_DEFCONFIG:-sun60iw2p1_t736_defconfig}"
CROSS_COMPILE="${CROSS_COMPILE:-arm-linux-gnueabi-}"   # vendor U-Boot runs in AArch32

OUT="${OUT:-$(pwd)}"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
mkdir -p "${OUT}"

# --- Dependency / host checks ------------------------------------------------
need() { command -v "$1" >/dev/null 2>&1 || { echo "MISSING TOOL: $1 ($2)"; exit 3; }; }
need git "git"
need "${CROSS_COMPILE}gcc" "32-bit ARM cross-compiler (apt: gcc-arm-linux-gnueabi)"
need cc "host C compiler (build-essential)"
need flex "flex"; need bison "bison"; need m4 "m4"
need xxd "xxd (apt: xxd) - vendor U-Boot generates sunxi_challenge.c with it"

QEMU=""
if [[ "$(uname -m)" != "x86_64" ]]; then
    qemu_bin="$(command -v qemu-x86_64-static || command -v qemu-x86_64 || true)"
    [[ -n "${qemu_bin}" ]] || { echo "MISSING TOOL: qemu-x86_64-static (apt: qemu-user-static) - needed to run Allwinner x86 pack tools on $(uname -m)"; exit 3; }
    # Armbian exports QEMU_CPU=cortex-a53 for its aarch64 chroot emulation. That
    # value is meaningless to qemu-x86_64 ("unable to find CPU model 'cortex-a53'")
    # and aborts the x86 pack tools, so strip it from their environment.
    QEMU="env -u QEMU_CPU ${qemu_bin}"
fi

clone_pinned() {  # repo ref dest [sparse_path]
    local repo="$1" ref="$2" dest="$3" sparse="${4:-}"
    git init -q "${dest}"
    git -C "${dest}" remote add origin "${repo}"
    if [[ -n "${sparse}" ]]; then
        git -C "${dest}" config core.sparseCheckout true
        echo "${sparse}" > "${dest}/.git/info/sparse-checkout"
    fi
    # Fetch the exact commit shallowly (GitHub allows fetch-by-SHA).
    git -C "${dest}" fetch -q --depth 1 origin "${ref}"
    git -C "${dest}" checkout -q FETCH_HEAD
}

echo ">>> Cloning Orange Pi U-Boot @ ${OPI_UBOOT_REF:0:12} ..."
clone_pinned "${OPI_UBOOT_REPO}" "${OPI_UBOOT_REF}" "${WORK}/u-boot"
echo ">>> Cloning orangepi-build pack-uboot @ ${OPI_BUILD_REF:0:12} ..."
clone_pinned "${OPI_BUILD_REPO}" "${OPI_BUILD_REF}" "${WORK}/opibuild" "external/packages/pack-uboot/*"

UBOOT_SRC="${WORK}/u-boot"
PACK="${WORK}/opibuild/external/packages/pack-uboot"
[[ -d "${PACK}/sun60iw2/bin" && -d "${PACK}/tools" ]] || { echo "pack-uboot layout not found in orangepi-build @ ${OPI_BUILD_REF}"; exit 4; }

# --- 1. Build vendor U-Boot from source (AArch32, gcc-compat flags) ----------
echo ">>> Building U-Boot (${UBOOT_DEFCONFIG}) ..."
cd "${UBOOT_SRC}"
export CROSS_COMPILE
export KCFLAGS="-fcommon -Wno-error -Wno-attributes -Wno-array-bounds -Wno-maybe-uninitialized -Wno-stringop-overflow"
make "${UBOOT_DEFCONFIG}"
# The vendor tree ships an x86-only scripts/dtc/dtc; rebuild it natively if needed.
if ! ./scripts/dtc/dtc --version >/dev/null 2>&1; then
    rm -f scripts/dtc/dtc
    make -f scripts/Makefile.build obj=scripts/dtc srctree=. objtree="$(pwd)" \
         HOSTCC=cc HOSTCFLAGS="-O2 -fcommon" LEX=flex YACC=bison
fi
# Ensure include/autoconf.mk exists (board-header #defines -> make vars).
make CROSS_COMPILE="${CROSS_COMPILE}" include/config/auto.conf
make -j"$(nproc)" CROSS_COMPILE="${CROSS_COMPILE}" KCFLAGS="${KCFLAGS}"
[[ -f u-boot.bin ]] || { echo "u-boot.bin was not produced"; exit 5; }

# --- 2. Pack boot0 + boot_package (mirrors orangepi-build postprocess) -------
echo ">>> Packing boot images ..."
cd "${WORK}"
cp -r "${PACK}/sun60iw2/bin/"* .
cp boot0_sdcard_a733.fex boot0_sdcard.fex
cp boot0_spinor_a733.fex boot0_spinor.fex
cp "${UBOOT_SRC}/u-boot.bin" u-boot.fex
"${UBOOT_SRC}/scripts/dtc/dtc" -p 2048 -W no-unit_address_vs_reg -@ -O dtb \
    -o opi4pro-u-boot.dtb -b 0 dts/u-boot-current.dts
cp sys_config/sys_config.fex sys_config.fex
sed -i 's/$/\r/' sys_config.fex                     # unix2dos
${QEMU:+$QEMU} "${PACK}/tools/script"      sys_config.fex     # -> sys_config.bin
cp opi4pro-u-boot.dtb sunxi.fex
${QEMU:+$QEMU} "${PACK}/tools/update_dtb"  sunxi.fex 4096
${QEMU:+$QEMU} "${PACK}/tools/update_uboot" -no_merge u-boot.fex sys_config.bin
sed -i 's/$/\r/' boot_package.cfg
${QEMU:+$QEMU} "${PACK}/tools/dragonsecboot" -pack boot_package.cfg

# --- 3. Deliver -------------------------------------------------------------
for f in boot0_sdcard.fex boot0_spinor.fex boot_package.fex; do
    [[ -f "${WORK}/${f}" ]] || { echo "expected output missing: ${f}"; exit 6; }
    cp "${WORK}/${f}" "${OUT}/${f}"
done
echo ">>> Done. Outputs in ${OUT}:"
ls -la "${OUT}"/boot0_sdcard.fex "${OUT}"/boot0_spinor.fex "${OUT}"/boot_package.fex
