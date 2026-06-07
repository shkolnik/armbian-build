# Allwinner A733 octa core 2-16GB RAM GBE USB3 WiFi/BT NVMe eMMC
BOARD_NAME="Orange Pi 4 Pro"
BOARDFAMILY="sun60iw2"
BOARD_MAINTAINER=""
KERNEL_TARGET="vendor"
BOOT_FDT_FILE="allwinner/sun60i-a733-orangepi-4-pro.dtb"
OVERLAY_PREFIX="sun60i-a733"
IMAGE_PARTITION_TABLE="msdos"

enable_extension "radxa-aic8800"
AIC8800_TYPE="sdio"
