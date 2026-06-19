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
   source (6.6 kernel-API-drift patch + the `$(srctree)/$(src)→$(M)` Kbuild fix) to
   `/usr/src/galcore-6.4.15.3.690884`, then `dkms add/build/install` (`CONFIG_AW_NNA_GALCORE=m`).
   `AUTOINSTALL=yes`, so the module **auto-rebuilds on kernel updates**.
2. DKMS installs the module to `/lib/modules/$(uname -r)/updates/dkms/` (+ `depmod`); the script
   keeps vipcore off normal autoload, adds a `/dev/galcore` udev rule, and installs a **boot
   kickstart oneshot** (`npu-galcore-kickstart.service`) that loads in-tree vipcore to bring the
   NPU up → unloads it → loads galcore, every boot (galcore can't cold-init — see below).
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
notes/23). **Revert:** disable+remove `npu-galcore-kickstart.service`, `dkms remove -m galcore -v
6.4.15.3.690884 --all`, remove the modprobe/udev drop-ins, `depmod`, then `enable-npu-vipcore`.

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

## NPU reboot-robustness — galcore needs the vipcore kickstart (root cause, verified 2026-06-19)

**The OOT galcore 6.4.15 cannot cold-init the NPU**, so on its own it goes dark on **every reboot**
(`chipModel=0x0`, `probe of 3600000.npu failed with error -22`). Its boot log shows what it's
missing: `NPU AXI CLK NULL`, `NPU AHB CLK NULL`, `Get NPU VOL FAIL!`, `Unable to find node` — it does
not acquire the NPU's clocks/regulator, only attaches to an already-powered NPU. The in-tree
**vipcore** driver does the full clock/reset/power bring-up, so the `enable-npu` **kickstart oneshot**
(load vipcore → unload → load galcore) makes galcore reboot-robust. Verified: clean reboot →
`/dev/galcore`, `model=9000`. **vipcore alone is reboot-robust without any kickstart.**

This is the real explanation for the earlier "went dark" scare: galcore was active (vipcore
blacklisted), a reboot darked it, and every recovery attempt was galcore-only so it stayed dark; a
reflash "fixed" it only because a fresh image boots vipcore by default. (Earlier drafts wrongly blamed
a hardware power-island latch, then a hand-edited DTB — both disproven; the reboot, not the DTB, was
the trigger.) **Recovery if galcore is dark (no reflash):** `modprobe vipcore && modprobe -r vipcore
&& modprobe galcore`, or just start `npu-galcore-kickstart.service`. The cleaner long-term fix is to
port vipcore's clock/regulator setup into galcore so it self-inits. Full record + reproduction:
`notes/21` §7.

## Licensing

The userspace libs (VIPLite or Unified) are proprietary VeriSilicon/Allwinner blobs
redistributed by community repos with unstated terms — hence **opt-in fetch at runtime, never
bundled**. The galcore and vipcore kernel driver sources are dual MIT/GPL.
