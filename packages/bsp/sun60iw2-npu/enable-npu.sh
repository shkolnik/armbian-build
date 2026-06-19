#!/usr/bin/env bash
# enable-npu.sh — opt-in enabler for the A733 (sun60iw2) NPU, **Unified / OpenVX** path
# (galcore). This is the DEFAULT NPU path. The lite alternate is enable-npu-vipcore.sh
# (VIPLite/NBG). The two are MUTUALLY EXCLUSIVE — galcore and vipcore drive the same NPU
# regs/IRQ; this script blacklists vipcore and loads galcore instead. Installs
# non-redistributable userspace, so like the VIPLite + GPU enablers it is shipped but
# never run automatically.
#
# The kernel module is built + installed via DKMS, so it auto-rebuilds on kernel updates
# (mirrors the GPU enabler). Validated on hardware 2026-06-19: galcore 6.4.15 (DKMS) +
# matched 6.4.15 Unified userspace -> vxCreateContext SUCCESS, TIM-VX LeNet ran on the
# NPU. See notes/22 (§"★ RESOLVED") and packages/bsp/sun60iw2-npu/README.md.
#
# WHY 6.4.15 and not the in-tree driver: the gcHAL kernel<->userspace versions must
# match EXACTLY. Our BSP's in-tree galcore is 6.4.18, but the only public Unified
# userspace is 6.4.15 -> a 6.4.18 driver fails vxCreateContext with NO_RESOURCES
# (OPi bug #302). So we DO NOT enable CONFIG_AW_NNA_GALCORE; we DKMS-build the 6.4.15
# driver from MaverickLong's package (6.4.15 source + a 6.6 kernel-API-drift patch).
#
# NOTE (board DT): galcore is OPP-exact — it reads `npu-vf` and demands that exact OPP.
# The OPi 4 Pro DT cap must set `npu-vf = <0x354>` (852MHz) for galcore to clock
# correctly (see the board patch). Without it the NPU falls back to an unmanaged clock.
set -euo pipefail

# --- pinned sources ---------------------------------------------------------
GALCORE_REPO="https://github.com/MaverickLong/Radxa-A733-NPU-Unified-Driver-Support-Package.git"
GALCORE_COMMIT="69548908aeedfa349a63d6a268ae0c88e0d18ee3"   # galcore 6.4.15.3.690884 + 6.6 drift patch
AISDK_REPO="https://github.com/ZIFENG278/ai-sdk.git"
AISDK_COMMIT="fc90006d0f6569da2f6726c2d8395877686f5aca"     # Unified userspace 6.4.15.3.690884
GCHAL_VER="6.4.15.3.690884"
INC="unified-tina/inc"
UNI="unified-tina/lib/aarch64-none-linux-gnu"

LIBDIR="/usr/local/lib/npu-unified"
INCDIR="/usr/local/include/npu-unified"
WORK="/var/cache/npu-galcore-build"
SRCDIR="/usr/src/galcore-${GCHAL_VER}"   # DKMS source tree (must live under /usr/src)
KREL="$(uname -r)"

# Re-exec under sudo so running == next boot.
if [[ $EUID -ne 0 ]]; then exec sudo -E "$0" "$@"; fi

echo "== A733 NPU Unified/OpenVX (galcore) enabler =="

# --- 0. prerequisites -------------------------------------------------------
[[ -d "/lib/modules/${KREL}/build" ]] || { echo "FATAL: linux-headers-${KREL} missing"; exit 1; }
for t in gcc make git; do command -v "$t" >/dev/null || { echo "FATAL: need $t"; exit 1; }; done
if ! command -v dkms >/dev/null; then
    echo "Installing dkms..."
    apt-get update -qq || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends dkms \
        || { echo "FATAL: could not install dkms"; exit 1; }
fi

mkdir -p "$WORK"; cd "$WORK"

# --- 1. fetch + patch galcore 6.4.15 source, stage for DKMS -----------------
if [[ ! -d galcore-pkg/.git ]]; then
    rm -rf galcore-pkg && git clone "$GALCORE_REPO" galcore-pkg
fi
git -C galcore-pkg fetch -q origin "$GALCORE_COMMIT" && git -C galcore-pkg checkout -q "$GALCORE_COMMIT"
(
    cd galcore-pkg
    grep -q "$GCHAL_VER" aw_nna_galcore/hal/inc/gc_hal_version.h \
        || { echo "FATAL: galcore source is not ${GCHAL_VER}"; exit 1; }
    # Apply the 6.6 kernel-API-drift patch (patch -p1 at package root; the repo's
    # apply_*.bash uses git-apply which needs a git toplevel a fresh checkout lacks).
    if ! patch -p1 --reverse --dry-run <galcore_6.6_kernel_api_drift.patch >/dev/null 2>&1; then
        patch -p1 <galcore_6.6_kernel_api_drift.patch
    fi
    # Vendor build glue uses $(srctree)/$(src), which only resolves for in-tree builds;
    # rewrite to $(M) for the OOT/DKMS (M=) build. Idempotent (no-op once rewritten).
    for f in aw_nna_galcore/Kbuild aw_nna_galcore/Makefile; do
        if [[ -f "$f" ]] && grep -q 'srctree)/$(src)' "$f"; then
            sed -i 's|$(srctree)/$(src)|$(M)|g' "$f"
        fi
    done
    true   # don't let a short-circuited && above become the subshell's exit status
)

# Stage a clean patched tree into /usr/src (DKMS source of truth) + write dkms.conf.
rm -rf "$SRCDIR"; mkdir -p "$SRCDIR"
cp -a galcore-pkg/aw_nna_galcore "$SRCDIR/aw_nna_galcore"
find "$SRCDIR/aw_nna_galcore" \( -name '*.o' -o -name '*.ko' -o -name '*.mod*' \
    -o -name '.*.cmd' -o -name 'Module.symvers' -o -name 'modules.order' \) -delete
cat > "$SRCDIR/dkms.conf" <<EOF
PACKAGE_NAME="galcore"
PACKAGE_VERSION="${GCHAL_VER}"
BUILT_MODULE_NAME[0]="galcore"
BUILT_MODULE_LOCATION[0]="aw_nna_galcore"
DEST_MODULE_LOCATION[0]="/updates"
MAKE[0]="make -C \${kernel_source_dir} M=\${dkms_tree}/\${PACKAGE_NAME}/\${PACKAGE_VERSION}/build/aw_nna_galcore CONFIG_AW_NNA_GALCORE=m modules"
CLEAN="make -C \${kernel_source_dir} M=\${dkms_tree}/\${PACKAGE_NAME}/\${PACKAGE_VERSION}/build/aw_nna_galcore clean"
AUTOINSTALL="yes"
EOF

# --- 2. DKMS build + install, exclude vipcore -------------------------------
dkms status -m galcore -v "$GCHAL_VER" 2>/dev/null | grep -q . \
    && dkms remove -m galcore -v "$GCHAL_VER" --all >/dev/null 2>&1 || true
dkms add     -m galcore -v "$GCHAL_VER"
dkms build   -m galcore -v "$GCHAL_VER"
dkms install -m galcore -v "$GCHAL_VER" --force          # installs to updates/dkms/, runs depmod
echo "blacklist vipcore" > /etc/modprobe.d/npu-galcore-blacklist.conf   # galcore replaces vipcore
echo "galcore"           > /etc/modules-load.d/npu-galcore.conf
printf 'KERNEL=="galcore", MODE="0666"\n' > /etc/udev/rules.d/99-npu-galcore.rules
rm -f /etc/modules-load.d/npu.conf /etc/udev/rules.d/99-vipcore.rules   # drop the vipcore path's drop-ins (mutually exclusive)

# --- 3. install the matched Unified userspace 6.4.15 ------------------------
if [[ ! -d "ai-sdk/.git" ]]; then
    rm -rf ai-sdk && git clone --filter=blob:none --sparse "$AISDK_REPO" ai-sdk
fi
git -C ai-sdk checkout -q "$AISDK_COMMIT"
git -C ai-sdk sparse-checkout set "$INC" "$UNI"
grep -q "$GCHAL_VER" "ai-sdk/${INC}/HAL/gc_hal_version.h" \
    || echo "WARN: userspace gcHAL != ${GCHAL_VER} — version skew will break vxCreateContext"
install -d "$LIBDIR" "$INCDIR"
cp -a "ai-sdk/${UNI}/"*.so* "$LIBDIR/"
cp -r "ai-sdk/${INC}/." "$INCDIR/"
# Some libs ship X.so / X.so.N / X.so.N.M.P as identical real files; collapse the
# SONAME/dev aliases to symlinks so ldconfig doesn't warn (cosmetic).
( cd "$LIBDIR"
  for real in *.so.*.*.*; do
      [[ -e "$real" ]] || continue
      soname="${real%.*.*}"; link="${soname%.*}"
      ln -sf "$real" "$soname"; ln -sf "$soname" "$link"
  done )
echo "$LIBDIR" > /etc/ld.so.conf.d/npu-unified.conf
ldconfig

# --- 4. activate now (running == next boot) ---------------------------------
lsmod | awk '{print $1}' | grep -qx vipcore && { rmmod vipcore || true; }
modprobe -r galcore 2>/dev/null || true
modprobe galcore
[[ -e /dev/galcore ]] || { echo "FATAL: /dev/galcore did not appear (check dmesg)"; exit 1; }
udevadm trigger --name-match=galcore 2>/dev/null || true

# --- 5. self-test: version-matched OpenVX handshake -------------------------
cat > "${WORK}/vx_probe.c" <<'PROBE'
#include <stdio.h>
#include <VX/vx.h>
int main(void){
    vx_context c = vxCreateContext();
    if (vxGetStatus((vx_reference)c) != VX_SUCCESS){ printf("FAIL: vxCreateContext\n"); return 1; }
    char impl[VX_MAX_IMPLEMENTATION_NAME] = {0};
    vxQueryContext(c, VX_CONTEXT_IMPLEMENTATION, impl, sizeof(impl));
    printf("\nOpenVX context OK (implementation=%s)\n", impl);
    vxReleaseContext(&c);
    return 0;
}
PROBE
if gcc "${WORK}/vx_probe.c" -I"$INCDIR" -L"$LIBDIR" -Wl,-rpath-link,"$LIBDIR" -lOpenVX -o "${WORK}/vx_probe" 2>/dev/null; then
    if VIVANTE_SDK_DIR="$INCDIR/.." LD_LIBRARY_PATH="$LIBDIR" "${WORK}/vx_probe"; then
        echo "NPU self-test PASSED — galcore ${GCHAL_VER} <-> Unified/OpenVX userspace OK"
    else
        echo "NPU self-test FAILED — check version match and dmesg"; exit 1
    fi
else
    echo "WARN: self-test probe didn't compile (libs installed; check headers)"
fi

cat <<EOF

Done. Unified/OpenVX path is live:
  driver : galcore ${GCHAL_VER}  (DKMS; /dev/galcore; vipcore blacklisted)
  libs   : ${LIBDIR}   headers: ${INCDIR}
To run real models build TIM-VX against the SDK (EXTERNAL_VIV_SDK), then ONNX-RT/TFLite.
Revert to the VIPLite path:
  dkms remove -m galcore -v ${GCHAL_VER} --all
  rm -f /etc/modprobe.d/npu-galcore-blacklist.conf /etc/modules-load.d/npu-galcore.conf \\
        /etc/udev/rules.d/99-npu-galcore.rules
  depmod ${KREL}; rmmod galcore; enable-npu-vipcore   # or: modprobe vipcore
EOF
