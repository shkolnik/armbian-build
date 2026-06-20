# sun60iw2-npu — opt-in VeriSilicon VIP9000 NPU enablers (Allwinner A733)

The A733's VeriSilicon **VIP9000** NPU (~3 TOPS) has two software stacks. This package
ships an opt-in enabler for each; both are shipped to `/usr/local/sbin/` but **never run
automatically** (they install non-redistributable userspace — same policy as the GPU
enabler). The two paths are **mutually exclusive** (galcore and vipcore drive the same
NPU registers/IRQ).

| Script | Path | Kernel driver | Userspace | Runtime |
|---|---|---|---|---|
| **`enable-npu`** (default) | Unified / OpenVX | **galcore** `/dev/galcore` | `libGAL`/`libOpenVX`/`libVSC`/`libCLC`/`libovxlib` | OpenVX + OpenCL + JIT → **TIM-VX → ONNX-RT / TFLite** (broad ops, CPU fallback) |
| `enable-npu-vipcore` | VIPLite / NBG | **vipcore** `/dev/vipcore` (in-tree) | `libVIPhal`+`libNBGlinker` | precompiled **NBG only** (no JIT/op-fallback), `vpm_run` |

Pick **`enable-npu`** (galcore) for real-world models — it's the richer path that standard
runtimes ride on. Use `enable-npu-vipcore` only for the minimal precompiled-NBG runtime.

## `enable-npu` — Unified / OpenVX (galcore) — DEFAULT

What it does, on the running kernel (`linux-headers` must be present; installs `dkms` if absent):
1. **Builds galcore 6.4.15 via DKMS** from MaverickLong's package (pinned) — stages the patched
   source (6.6 kernel-API-drift patch + the `$(srctree)/$(src)→$(M)` Kbuild fix + the **A733
   self-init patch** that adds the gate clocks galcore needs to cold-init the NPU) to
   `/usr/src/galcore-6.4.15.3.690884`, then `dkms add/build/install` (`CONFIG_AW_NNA_GALCORE=m`).
   `AUTOINSTALL=yes`, so the module **auto-rebuilds on kernel updates**.
2. DKMS installs the module to `/lib/modules/$(uname -r)/updates/dkms/` (+ `depmod`); the script
   keeps vipcore off normal autoload, adds a `/dev/galcore` udev rule, and sets galcore to
   **autoload at boot** (`/etc/modules-load.d/npu-galcore.conf`). With the self-init patch galcore
   powers the NPU itself, so **no vipcore kickstart is needed** (see below).
3. Installs the matched **Unified userspace 6.4.15** (ai-sdk `unified-tina`, pinned, sparse) to
   `/usr/local/lib/npu-unified` (+ `ldconfig`), headers to `/usr/local/include/npu-unified`. The
   OpenVX libs ship the `.so`/`.so.1`/`.so.1.3.0` triplet as identical real files; the script
   collapses the SONAME/dev aliases to symlinks so `ldconfig` stays quiet.
4. Activates now (rmmod vipcore → modprobe galcore) and **self-tests** a `vxCreateContext`
   handshake against the userspace.

Idempotent (safe to re-run), re-execs under sudo, activates now so running == next boot.

**Why galcore 6.4.15 and not the in-tree driver:** the gcHAL kernel↔userspace versions must
match **exactly**. Our BSP's in-tree galcore is **6.4.18**, but the only public Unified
userspace is **6.4.15** — a 6.4.18 driver fails `vxCreateContext` with `NO_RESOURCES`
(orangepi-build bug #302). So the enabler does **not** enable `CONFIG_AW_NNA_GALCORE`; it
DKMS-builds the 6.4.15 driver to match the userspace. Validated on HW 2026-06-19: clean run
as a shipped unit, handshake OK, and TIM-VX **LeNet ran on the NPU** (see notes/22 §"★ RESOLVED",
notes/23). **Revert:** `dkms remove -m galcore -v 6.4.15.3.690884 --all`, remove the
modprobe/udev/modules-load drop-ins, `depmod`, then `enable-npu-vipcore`.

**Running your own model:** build **TIM-VX** against the userspace (`-DEXTERNAL_VIV_SDK`),
then ONNX-Runtime (VSINPU EP) or TFLite (VX delegate). A standalone bring-up/validation
recipe lives at the project root: `npu-galcore-timvx-bringup.sh`. Known A733 caveats: cast
conv/FC operands to UINT8; use FullyConnected instead of batched MatMul.

## `enable-npu-vipcore` — VIPLite / NBG (alternate)

The kernel driver (`vipcore.ko`, `CONFIG_AW_NNA_VIP=m`+`NNA_VIP2=y`) is **in-tree** and
autoloads → `/dev/vipcore`. This script installs the **VIPLite v2.0 userspace** (`libVIPhal`+
`libNBGlinker`, pinned ai-sdk, sparse) to `/usr/local/lib/npu`, builds **`vpm_run`** (generic
NBG runner) + a sample, adds a udev rule, and self-tests a `v3` NBG (`vip lite init OK`,
`cid=0x1000003b`, `ret=0`). Runs a **precompiled NBG only** — convert ONNX/TFLite→NBG
off-device (ACUITY or TIM-VX). Validated on HW (`2.0.3.2-AW` userspace ↔ `2.0.3.4-AW` kernel).

## Version coupling (important, both paths)

- **galcore/Unified:** gcHAL versions must match **exactly** — `6.4.15.3.690884` on both sides
  (a build-digit skew is NOT tolerated; that's the whole reason for the 6.4.15 driver build).
- **vipcore/VIPLite:** keys on ABI `0x00020003` (= `2.0.3.x`); the trailing build digit doesn't
  gate, so userspace `2.0.3.2-AW` pairs with kernel `2.0.3.4-AW`.

If you bump either side of either path, re-check the handshake.

## NPU clock is capped at 852 MHz on this board (both paths)

On the **Orange Pi 4 Pro** `VDD-NPU` shares the 0.8 V `DCDC2` rail (HDMI/DRAM/UFS/combo-PHYs),
so the NPU cannot reach the 0.96 V its 1008 MHz OPP needs — running 1008 MHz undervolts the NPU
and causes **intermittent silent compute errors**. The board DT patch
`0005-orangepi4pro-cap-npu-852mhz.patch` caps at 852 MHz: it deletes the 1008/1120 MHz OPPs
(caps vipcore, which selects the top OPP) **and** retargets `npu-vf` to `0x354` (852 — required
because galcore is OPP-exact). Board-specific; other A733 boards with a dedicated NPU rail may
keep 1008 MHz. (vipcore validated 10000/10000 golden at 852; the combined patch warrants a
quick re-validation of both drivers at clean-test.)

## NPU reboot-robustness — galcore self-inits via the gate-clock patch (verified 2026-06-19)

**galcore now powers the NPU itself and survives reboots with no vipcore kickstart.** The bundled
**A733 self-init patch** (`galcore-a733-selfinit.patch`, applied during DKMS staging) fixes the one
gap that used to require the kickstart.

The gap: galcore's stock Allwinner glue is **VIP1-era** — it requests legacy `npu-aclk`/`npu-hclk`
(absent in the A733 DT → the harmless `NPU AXI/AHB CLK NULL` notices) and **never requested the A733
gate clocks** (`clk_bus`, `clk_mbus_gate`, `clk_ahb_gate`). Without those gates the NPU bus is
unclocked, so registers read `chipModel=0x0` and probe fails `-22` — galcore could only *attach* to an
already-powered NPU, which is why it needed the in-tree **vipcore** to bring the silicon up first. The
patch adds those three gate clocks to `_AdjustParam` (mirroring vipcore's VIP2 `npu_clk_init` order:
deassert resets → enable ahb_gate/mbus_gate/bus → module clock) and fixes a stray
`aclk`-checked-twice bug. Validated on HW: cold boot + 2 reboots → galcore autoloads alone (vipcore
blacklisted), `/dev/galcore` `model=9000`, `vxCreateContext` OK.

**Clock rate:** galcore's OPP/voltage parse still fails (`Get NPU VOL FAIL!`, `rate:0`), so it runs the
NPU at the PLL default (~840 MHz) instead of reading `npu-vf`. SAFE on the OPi 4 Pro: 840 < the 852
cap on the shared 0.8 V DCDC2 rail → no undervolt. The `npu-vf=852` DT cap still governs the vipcore
path. (Porting galcore's OPP rate-set is a future polish.)

Earlier "went dark on reboot" drafts wrongly blamed a hardware power-island latch, then a hand-edited
DTB, then a vipcore-kickstart dependency — the kickstart worked but only masked the missing gate
clocks. **If galcore is ever dark on an old (pre-patch) image:** `modprobe vipcore && modprobe -r
vipcore && modprobe galcore`. Full record + reproduction: `notes/21` §7.

## Licensing

The userspace libs (VIPLite or Unified) are proprietary VeriSilicon/Allwinner blobs
redistributed by community repos with unstated terms — hence **opt-in fetch at runtime, never
bundled**. The galcore and vipcore kernel driver sources are dual MIT/GPL.
