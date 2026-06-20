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
# WHY the self-init patch: galcore's stock Allwinner glue is VIP1-era — it requests legacy
# `npu-aclk`/`npu-hclk` (absent on A733) and never the A733 gate clocks (clk_bus/clk_mbus_gate/
# clk_ahb_gate), so it couldn't cold-init the NPU (logs `AXI/AHB CLK NULL`, reads chipModel=0x0,
# probe -22) and used to need a vipcore "kickstart" each boot. The embedded
# galcore-a733-selfinit.patch (applied below) adds those three gate clocks to _AdjustParam,
# mirroring vipcore's VIP2 bring-up, so galcore powers the NPU itself and survives reboots with
# NO kickstart. Validated on HW 2026-06-19 (cold-init + 2 reboots). Root cause: notes/21 §7.
#
# NOTE (clock rate): galcore's OPP/voltage parse still fails (`VOL FAIL`, rate:0), so it runs
# the NPU at the PLL default (~840MHz) rather than reading `npu-vf`. That's SAFE on the OPi
# 4 Pro: 840 < the 852 cap on the shared 0.8V DCDC2 rail, so no undervolt. The board DT cap
# (deleted 1008/1120 OPPs) governs the vipcore path. (galcore's OPP rate-set is a future polish.)
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

# A733 self-init patch (our addition): add the gate clocks galcore needs to cold-init the
# NPU, so no vipcore kickstart is required. Applied with patch -p1 at the package root.
cat > "${WORK}/galcore-a733-selfinit.patch" <<'SELFINIT'
--- a/aw_nna_galcore/os/platform/allwinner/gc_hal_kernel_platform_allwinner.c
+++ b/aw_nna_galcore/os/platform/allwinner/gc_hal_kernel_platform_allwinner.c
@@ -282,9 +282,21 @@ gceSTATUS _AdjustParam(IN gcsPLATFORM *Platform, OUT gcsMODULE_PARAMETERS *Args)
 	if (IS_ERR_OR_NULL(aw_driver.aclk))
 		pr_notice("NPU AXI CLK NULL\n");
 	aw_driver.hclk = of_clk_get_by_name(pdev->dev.of_node, "npu-hclk");
-	if (IS_ERR_OR_NULL(aw_driver.aclk))
+	if (IS_ERR_OR_NULL(aw_driver.hclk))
 		pr_notice("NPU AHB CLK NULL\n");

+	/* A733 (sun60iw2) bus + gate clocks — without these the NPU bus is unclocked
+	 * and registers read 0x0. vipcore enables them; galcore's VIP1-era glue didn't. */
+	aw_driver.bus = of_clk_get_by_name(pdev->dev.of_node, "clk_bus");
+	if (IS_ERR_OR_NULL(aw_driver.bus))
+		pr_notice("NPU BUS CLK NULL\n");
+	aw_driver.mbus_gate = of_clk_get_by_name(pdev->dev.of_node, "clk_mbus_gate");
+	if (IS_ERR_OR_NULL(aw_driver.mbus_gate))
+		pr_notice("NPU MBUS GATE NULL\n");
+	aw_driver.ahb_gate = of_clk_get_by_name(pdev->dev.of_node, "clk_ahb_gate");
+	if (IS_ERR_OR_NULL(aw_driver.ahb_gate))
+		pr_notice("NPU AHB GATE NULL\n");
+
 	aw_driver.arst = devm_reset_control_get(&pdev->dev, "npu_axi_rst");
 	if (IS_ERR_OR_NULL(aw_driver.arst))
 		pr_notice("NPU AXI RST NULL\n");
@@ -339,28 +351,49 @@ gceSTATUS _AdjustParam(IN gcsPLATFORM *Platform, OUT gcsMODULE_PARAMETERS *Args)
 #if IS_ENABLED(CONFIG_AW_PM_DOMAINS)
 		pm_runtime_enable(dev);
 #else
-		if (!IS_ERR_OR_NULL(aw_driver.hclk)) {
-			if (clk_prepare_enable(aw_driver.hclk)) {
-				pr_err("galcore: Couldn't enable AHB clock\n");
+		/* Order mirrors vipcore's VIP2 npu_clk_init: deassert resets, then
+		 * gate clocks (ahb_gate, mbus_gate, bus), then bus/module clocks. */
+		if (!IS_ERR_OR_NULL(aw_driver.hrst)) {
+			if (reset_control_deassert(aw_driver.hrst)) {
+				pr_err("galcore: Couldn't deassert AHB RST\n");
 				return -EBUSY;
 			}
 		}
-		if (!IS_ERR_OR_NULL(aw_driver.aclk)) {
-			if (clk_prepare_enable(aw_driver.aclk)) {
-				pr_err("galcore: Couldn't enable AXI clock\n");
+		if (!IS_ERR_OR_NULL(aw_driver.arst)) {
+			if (reset_control_deassert(aw_driver.arst)) {
+				pr_err("galcore: Couldn't deassert AXI RST\n");
 				return -EBUSY;
 			}
 		}

-		if (!IS_ERR_OR_NULL(aw_driver.hrst)) {
-			if (reset_control_deassert(aw_driver.hrst)) {
-				pr_err("galcore: Couldn't deassert AHB RST\n");
+		if (!IS_ERR_OR_NULL(aw_driver.ahb_gate)) {
+			if (clk_prepare_enable(aw_driver.ahb_gate)) {
+				pr_err("galcore: Couldn't enable AHB GATE clock\n");
 				return -EBUSY;
 			}
 		}
-		if (!IS_ERR_OR_NULL(aw_driver.arst)) {
-			if (reset_control_deassert(aw_driver.arst)) {
-				pr_err("galcore: Couldn't deassert AXI RST\n");
+		if (!IS_ERR_OR_NULL(aw_driver.mbus_gate)) {
+			if (clk_prepare_enable(aw_driver.mbus_gate)) {
+				pr_err("galcore: Couldn't enable MBUS GATE clock\n");
+				return -EBUSY;
+			}
+		}
+		if (!IS_ERR_OR_NULL(aw_driver.bus)) {
+			if (clk_prepare_enable(aw_driver.bus)) {
+				pr_err("galcore: Couldn't enable BUS clock\n");
+				return -EBUSY;
+			}
+		}
+
+		if (!IS_ERR_OR_NULL(aw_driver.hclk)) {
+			if (clk_prepare_enable(aw_driver.hclk)) {
+				pr_err("galcore: Couldn't enable AHB clock\n");
+				return -EBUSY;
+			}
+		}
+		if (!IS_ERR_OR_NULL(aw_driver.aclk)) {
+			if (clk_prepare_enable(aw_driver.aclk)) {
+				pr_err("galcore: Couldn't enable AXI clock\n");
 				return -EBUSY;
 			}
 		}
--- a/aw_nna_galcore/os/platform/allwinner/gc_hal_kernel_platform_allwinner.h
+++ b/aw_nna_galcore/os/platform/allwinner/gc_hal_kernel_platform_allwinner.h
@@ -22,6 +22,9 @@ typedef struct _aw_driver_t {
 	struct clk *pclk;
 	struct clk *aclk;
 	struct clk *hclk;
+	struct clk *bus;
+	struct clk *mbus_gate;
+	struct clk *ahb_gate;
 	struct reset_control *arst;
 	struct reset_control *hrst;
 	struct regulator *regulator;
SELFINIT

(
    cd galcore-pkg
    grep -q "$GCHAL_VER" aw_nna_galcore/hal/inc/gc_hal_version.h \
        || { echo "FATAL: galcore source is not ${GCHAL_VER}"; exit 1; }
    # Apply the 6.6 kernel-API-drift patch (patch -p1 at package root; the repo's
    # apply_*.bash uses git-apply which needs a git toplevel a fresh checkout lacks).
    if ! patch -p1 --reverse --dry-run <galcore_6.6_kernel_api_drift.patch >/dev/null 2>&1; then
        patch -p1 <galcore_6.6_kernel_api_drift.patch
    fi
    # Apply our A733 self-init patch (gate clocks) — idempotent (skip if already applied).
    if ! patch -p1 --reverse --dry-run <"${WORK}/galcore-a733-selfinit.patch" >/dev/null 2>&1; then
        patch -p1 <"${WORK}/galcore-a733-selfinit.patch"
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
echo "blacklist vipcore" > /etc/modprobe.d/npu-galcore-blacklist.conf   # keep vipcore off normal autoload
printf 'KERNEL=="galcore", MODE="0666"\n' > /etc/udev/rules.d/99-npu-galcore.rules
# galcore self-inits the NPU now (gate-clock patch), so just load it directly at boot.
echo galcore > /etc/modules-load.d/npu-galcore.conf
# Drop the vipcore path's drop-ins.
rm -f /etc/modules-load.d/npu.conf /etc/udev/rules.d/99-vipcore.rules
# Remove any prior vipcore "kickstart" (older enabler versions) — no longer needed.
if [[ -e /etc/systemd/system/npu-galcore-kickstart.service ]]; then
    systemctl disable --now npu-galcore-kickstart.service >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/npu-galcore-kickstart.service
    systemctl daemon-reload
fi

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
# galcore self-inits the NPU (gate-clock patch), so no vipcore needed — just (re)load it.
modprobe -r galcore 2>/dev/null || true
modprobe -r vipcore 2>/dev/null || true
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
  rm -f /etc/modprobe.d/npu-galcore-blacklist.conf /etc/udev/rules.d/99-npu-galcore.rules /etc/modules-load.d/npu-galcore.conf
  depmod ${KREL}; rmmod galcore; enable-npu-vipcore   # or: modprobe vipcore
EOF
