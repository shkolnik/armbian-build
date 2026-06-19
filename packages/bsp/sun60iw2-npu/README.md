# sun60iw2-npu — opt-in VeriSilicon VIP9000 NPU enabler (Allwinner A733)

`enable-npu.sh` turns on the A733's VeriSilicon **VIP9000** NPU (~3 TOPS) on Armbian
sun60iw2. It is **opt-in** and installs **non-redistributable** userspace, so it is shipped
to `/usr/local/sbin/` but never run automatically and nothing is baked into the image
(same policy as the GPU enabler).

## What works without this script

The kernel driver is **already in-tree**: our kernel builds `vipcore.ko`
(`CONFIG_AW_NNA_VIP=m` + `CONFIG_NNA_VIP2=y`), it autoloads at boot, and creates
`/dev/vipcore` (mode 0666). The board DT (`npu@3600000`) is enabled, the NPU is
firmware-less, and needs no CMA/reserved-memory. So out of the box the *kernel* side is
live — what's missing is the **userspace runtime** to submit a model to it.

## What the script does

1. Confirms `vipcore.ko` exists for the running kernel and sets it to autoload.
2. Fetches the **VIPLite v2.0 userspace** from Radxa's AI-SDK
   (`github.com/ZIFENG278/ai-sdk`, **pinned commit**, sparse blobless clone ≈ a few MB):
   `libVIPhal.so` + `libNBGlinker.so` → `/usr/local/lib/npu` (+ `ldconfig`), headers →
   `/usr/local/include/npu`.
3. Builds and installs **`vpm_run`** (the generic NBG runner) to `/usr/local/bin`, plus a
   sample `v3` NBG to `/usr/local/share/npu`.
4. Adds a udev rule for `/dev/vipcore`, `modprobe`s `vipcore`, and **self-tests**: runs the
   sample NBG and checks the kernel↔userspace handshake (`vip lite init OK`,
   `cid=0x1000003b`, `vpm run ret=0`).

Idempotent, re-execs under sudo, activates now so running == next boot.

## Version coupling (important)

Userspace and kernel share a strict ABI handshake `0x00020003` (= driver `2.0.3.x-AW`).
Our kernel ships `2.0.3.4-AW`; the pinned AI-SDK userspace is `2.0.3.2-AW` — these pair
cleanly (validated). If you bump either side, re-check: a mismatch makes `vip_init` fail
with a lib-version error even though the module loads.

## Running your own model

The NPU runs a precompiled **NBG** (`.nb`). Convert ONNX/TFLite → NBG **off-device** with
Allwinner's ACUITY toolkit (x86 Docker, `v3`/A733) or VeriSilicon **TIM-VX**, then:

```sh
printf '[network]\n/path/to/model.nb\n[input]\n/path/to/input.dat\n' > sample.txt
vpm_run -s sample.txt -l 1 --show_top5 1     # expect cid=0x1000003b, ret=0
```

## Note: NPU clock is capped at 852 MHz on this board

On the **Orange Pi 4 Pro** `VDD-NPU` shares the 0.8 V `DCDC2` rail (with HDMI/DRAM/UFS/
combo-PHYs), so the NPU cannot reach the 0.96 V its 1008 MHz OPP needs — running 1008 MHz
undervolts the NPU and causes **intermittent silent compute errors**. The board DT patch
`orangepi4pro: cap NPU at 852MHz` drops the 1008/1120 MHz OPPs so the driver tops out at
852 MHz @ 0.8 V (validated: 10000/10000 NPU golden compares pass). This is board-specific —
other A733 boards with a dedicated NPU rail may keep 1008 MHz.

## Licensing

The VIPLite userspace libs are a proprietary VeriSilicon/Allwinner blob redistributed by a
community repo with unstated terms — hence **opt-in fetch at runtime, never bundled**. The
kernel driver sources are dual MIT/GPL (already in-tree).
