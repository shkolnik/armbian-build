# Allwinner A733 octa core 2-16GB RAM GBE USB3 WiFi/BT NVMe eMMC
BOARD_NAME="Orange Pi 4 Pro"
BOARDFAMILY="sun60iw2"
BOARD_MAINTAINER=""
KERNEL_TARGET="vendor"
BOOT_FDT_FILE="allwinner/sun60i-a733-orangepi-4-pro.dtb"
OVERLAY_PREFIX="sun60i-a733"
IMAGE_PARTITION_TABLE="msdos"

# --- Kernel: Orange Pi's vendor BSP tree ---
# The sun60iw2 family file intentionally leaves kernel source to the board, so
# multiple A733 boards (which use different vendor kernel trees) can share the
# family. The Armbian build sources this board file before the family file, so
# these assignments win.
KERNELSOURCE="${GITHUB_SOURCE}/orangepi-xunlong/linux-orangepi.git"
case "${BRANCH}" in
	legacy)
		# BSP 5.15 (Bullseye-era; needed for working GPU/VPU blobs).
		# Add a linux-sun60iw2-opi-legacy.config before using KERNEL_TARGET=legacy.
		KERNELBRANCH="branch:orange-pi-5.15-sun60iw2"
		declare -g KERNEL_MAJOR_MINOR="5.15"
		;;
	vendor)
		# BSP 6.6 (current vendor kernel; default for this board).
		KERNELBRANCH="branch:orange-pi-6.6-sun60iw2"
		declare -g KERNEL_MAJOR_MINOR="6.6"
		;;
esac
KERNELPATCHDIR="archive/sun60iw2-opi-${BRANCH}"
LINUXCONFIG="linux-sun60iw2-opi-${BRANCH}"

# --- Boot: vendor U-Boot specifics ---
declare -g SERIALCON="ttyS0"
declare -g BOOTSCRIPT="boot-sun60iw2-opi.cmd:boot.cmd"
# The vendor U-Boot is a 32-bit ARM binary: uInitrd must be tagged arch=arm or
# bootm/booti rejects it ("No Linux ARM Ramdisk Image").
declare -g INITRD_ARCH="arm"
declare -g OFFSET=32
# Subdir under packages/blobs/sunxi/sun60iw2/ with this board's prebuilt boot
# blobs (boot0_sdcard.fex / boot_package.fex / boot0_spinor.fex); read by the
# family's build_custom_uboot. See that dir's README.md / build-boot-package.sh.
declare -g UBOOT_BLOB_DIR="opi4pro"

# --- WiFi/BT: AICSemi AIC8800D80 on SDIO (sdc1) ---
# Use the in-tree vendor modules (built =m in the vendor 6.6 kernel) rather than
# the radxa-aic8800 DKMS extension: that extension is gated on working kernel
# headers (the vendor kernel has none) and leaves a DKMS fdrv that mismatches the
# in-tree bsp ("Unknown symbol"). Loading aic8800_fdrv pulls aic8800_bsp (symbol
# dep), powers the chip, enumerates the SDIO card and creates wlan0. Firmware
# comes from armbian-firmware via the symlink in post_family_tweaks below.
# aic8800_btlpm = Bluetooth.
MODULES="aic8800_bsp aic8800_fdrv aic8800_btlpm"

# --- Board-specific rootfs tweaks (Armbian hook; runs after family_tweaks) ---
function post_family_tweaks__orangepi4pro() {
	display_alert "Orange Pi 4 Pro rootfs tweaks" "${BOARD}" "info"

	# Boot script loads uInitrd directly; minimal extraargs (headless server).
	echo "extraargs=coherent_pool=2M no_console_suspend fsck.fix=yes fsck.repair=yes" >> "${SDCARD}"/boot/armbianEnv.txt

	# AIC8800D80 WiFi/BT firmware: armbian-firmware ships the blobs at
	# /lib/firmware/aic8800/SDIO/aic8800D80/, but the in-tree vendor driver
	# requests them at the flat lowercase path /lib/firmware/aic8800d80/.
	if [[ -d "${SDCARD}/lib/firmware/aic8800/SDIO/aic8800D80" ]]; then
		ln -sfn aic8800/SDIO/aic8800D80 "${SDCARD}/lib/firmware/aic8800d80"
	else
		display_alert "aic8800D80 firmware not found in rootfs" "WiFi may not work; check armbian-firmware" "warn"
	fi

	# mtd-utils provides flash_erase/mtd_debug, needed by write_uboot_platform_mtd
	# (armbian-install "Boot from MTD Flash - system on NVMe").
	chroot_sdcard_apt_get_install mtd-utils
}
