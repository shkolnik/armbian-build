#!/bin/bash
#
# enable-npu-vipcore.sh — opt-in VeriSilicon VIP9000 NPU userspace, VIPLite/NBG path
# (Allwinner A733, sun60iw2). This is the *lite* alternate to enable-npu.sh (the default,
# galcore/Unified/OpenVX path). The two are MUTUALLY EXCLUSIVE — vipcore and galcore drive
# the same NPU regs/IRQ. Use this path for the precompiled-NBG runtime (no JIT/op-fallback).
#
# The kernel driver (vipcore.ko, CONFIG_AW_NNA_VIP) is in-tree and autoloads, so this only
# installs the non-redistributable VIPLite v2.0 userspace + the vpm_run runner, wires up the
# device node, and self-tests on /dev/vipcore. Validated on Orange Pi 4 Pro (headless Trixie):
# handshake 0x00020003, cid 0x1000003b, a v3 NBG ran on-NPU. See README.md.
#
# SPDX-License-Identifier: GPL-2.0
#

set -euo pipefail

# Proprietary VIPLite userspace (Radxa AI-SDK; libs are committed, not an apt package).
# Pinned for reproducibility; userspace is fetched on demand, never baked into the image.
AISDK_REPO="https://github.com/ZIFENG278/ai-sdk.git"
AISDK_COMMIT="fc90006d0f6569da2f6726c2d8395877686f5aca"      # 2025-10-20
AISDK_LIB="viplite-tina/lib/aarch64-none-linux-gnu/v2.0"     # A733 = NPU SW v2.0
# Minimal sparse set needed to install the libs and build vpm_run.
AISDK_SPARSE=(machinfo examples/vpm_run examples/libawnn_viplite examples/libawutils "${AISDK_LIB}")

NPU_LIBDIR="/usr/local/lib/npu"
NPU_INCDIR="/usr/local/include/npu"
NPU_SHARE="/usr/local/share/npu"

log() { echo ">> $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

# Needs root (apt, install to /usr/local + /etc, modprobe); re-exec under sudo.
if [[ ${EUID} -ne 0 ]]; then
	command -v sudo > /dev/null 2>&1 || die "must run as root (sudo not found)"
	log "Not root — re-running under sudo"
	exec sudo -- "$0" "$@"
fi

KVER="$(uname -r)"
case "${KVER}" in
	*sun60iw2*) ;;
	*) die "This is for sun60iw2 (A733) kernels; running kernel is '${KVER}'." ;;
esac
log "Target kernel: ${KVER}"

# --- Kernel side: module is in-tree, just confirm + autoload --------------------
log "Checking the in-tree NPU kernel driver (vipcore)"
modinfo vipcore > /dev/null 2>&1 || die "vipcore.ko not found for ${KVER}; kernel wasn't built with CONFIG_AW_NNA_VIP=m"
echo "vipcore" > /etc/modules-load.d/npu.conf

# --- Prerequisites + fetch userspace -------------------------------------------
log "Installing prerequisites (git, build tools)"
apt-get update
apt-get install -y --no-install-recommends git ca-certificates build-essential || die "could not install prerequisites"

tmpd="$(mktemp -d)"; trap 'rm -rf "${tmpd}"' EXIT
log "Fetching VIPLite userspace from ai-sdk @ ${AISDK_COMMIT:0:12} (sparse, blobless)"
git clone --filter=blob:none --sparse "${AISDK_REPO}" "${tmpd}/ai-sdk" || die "ai-sdk clone failed"
git -C "${tmpd}/ai-sdk" sparse-checkout set "${AISDK_SPARSE[@]}" || die "sparse-checkout failed"
git -C "${tmpd}/ai-sdk" checkout -q "${AISDK_COMMIT}" || die "could not check out pinned commit"
[[ -e "${tmpd}/ai-sdk/${AISDK_LIB}/libVIPhal.so" ]] || die "expected libs missing at ${AISDK_LIB}"

# --- Install runtime libs + headers --------------------------------------------
log "Installing VIPLite libs to ${NPU_LIBDIR}"
install -d "${NPU_LIBDIR}"
install -m 0644 "${tmpd}/ai-sdk/${AISDK_LIB}"/*.so "${NPU_LIBDIR}/"
echo "${NPU_LIBDIR}" > /etc/ld.so.conf.d/npu.conf
ldconfig
install -d "${NPU_INCDIR}"
cp -a "${tmpd}/ai-sdk/${AISDK_LIB}/inc/." "${NPU_INCDIR}/"

# --- Build + install vpm_run (generic NBG runner) + a self-test model -----------
log "Building vpm_run"
make -C "${tmpd}/ai-sdk/examples/vpm_run" AI_SDK_PLATFORM=a733 > /dev/null || die "vpm_run build failed"
install -m 0755 "${tmpd}/ai-sdk/examples/vpm_run/vpm_run" /usr/local/bin/
install -d "${NPU_SHARE}"
install -m 0644 "${tmpd}/ai-sdk/examples/vpm_run/operator/v3/network_binary.nb" "${NPU_SHARE}/"
install -m 0644 "${tmpd}/ai-sdk/examples/vpm_run/operator/input_0.dat" "${NPU_SHARE}/"

# --- Device node ---------------------------------------------------------------
# The driver already creates /dev/vipcore 0666; add an explicit rule for safety.
echo 'KERNEL=="vipcore", MODE="0666"' > /etc/udev/rules.d/99-vipcore.rules

# --- Activate now so running == next boot --------------------------------------
log "Loading the NPU module"
modprobe vipcore || die "modprobe vipcore failed; check dmesg"

# --- Self-test: run a v3 NBG and confirm the kernel<->userspace handshake -------
log "Self-testing the NPU (vpm_run on a v3 NBG)"
printf '[network]\n%s/network_binary.nb\n[input]\n%s/input_0.dat\n' "${NPU_SHARE}" "${NPU_SHARE}" > "${tmpd}/selftest.txt"
out="$(vpm_run -s "${tmpd}/selftest.txt" -l 1 2>&1)" || true
if grep -q "vip lite init OK" <<< "${out}" \
	&& grep -q "cid=0x1000003b" <<< "${out}" \
	&& grep -q "vpm run ret=0" <<< "${out}"; then
	log "NPU self-test PASSED — $(grep -oE 'VIPLite driver software version [0-9.]+-AW-[0-9-]+' <<< "${out}" | head -1)"
else
	die "NPU self-test failed; vpm_run output:\n${out}"
fi

log "Done. NPU active now and on boot; vpm_run + a sample NBG installed."
log "Convert your own ONNX→NBG (ACUITY or TIM-VX) and run: vpm_run -s <sample.txt> --show_top5 1"
