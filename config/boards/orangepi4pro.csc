# Allwinner A733 octa core 2-16GB RAM GBE USB3 WiFi/BT NVMe eMMC
BOARD_NAME="Orange Pi 4 Pro"
BOARDFAMILY="sun60iw2"
BOARD_MAINTAINER=""
KERNEL_TARGET="vendor"
BOOT_FDT_FILE="allwinner/sun60i-a733-orangepi-4-pro.dtb"
OVERLAY_PREFIX="sun60i-a733"
IMAGE_PARTITION_TABLE="msdos"

# WiFi/BT: AICSemi AIC8800D80 on SDIO (sdc1). Use the in-tree vendor modules
# (built =m in the vendor 6.6 kernel) rather than the radxa-aic8800 DKMS extension:
# that extension is gated on working kernel headers (the vendor kernel has none) and
# leaves a DKMS fdrv that mismatches the in-tree bsp ("Unknown symbol"). Loading
# aic8800_fdrv pulls aic8800_bsp (symbol dep), powers the chip, enumerates the SDIO
# card and creates wlan0. Firmware comes from the armbian-firmware package via a
# symlink created in family_tweaks (see sun60iw2.conf). aic8800_btlpm = Bluetooth.
MODULES="aic8800_bsp aic8800_fdrv aic8800_btlpm"
