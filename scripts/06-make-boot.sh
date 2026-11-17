#!/bin/bash
# Boot image for the OnePlus 6: header v0, Image.gz with the enchilada DTB appended, the OH ramdisk.
# It is only ever RAM-booted (fastboot boot); nothing is written to the boot partitions.
set -euo pipefail
. "$(dirname "$0")/config.sh"
mkb="$HOST_DIR/mkbootimg"
if [ ! -f "$mkb/mkbootimg.py" ]; then
  git clone -q "$MKBOOTIMG_URL" "$mkb"
fi
git -C "$mkb" checkout -q "$MKBOOTIMG_COMMIT"

kb="$KERNEL_OUT/arch/arm64/boot"
for f in "$kb/Image.gz" "$kb/dts/qcom/sdm845-oneplus-enchilada.dtb" "$IMAGES_DIR/ramdisk.img"; do
  [ -s "$f" ] || die "$f missing (run 04-build-kernel.sh and 05-build-oh.sh)"
done
kd=$(mktemp); trap 'rm -f "$kd"' EXIT
cat "$kb/Image.gz" "$kb/dts/qcom/sdm845-oneplus-enchilada.dtb" > "$kd"
cmdline="$BOOT_CMDLINE_BASE${BOOT_CMDLINE_EXTRA:+ $BOOT_CMDLINE_EXTRA}"
python3 "$mkb/mkbootimg.py" --header_version 0 --base 0 --kernel_offset 0x8000 --ramdisk_offset 0x1000000 \
  --second_offset 0xf00000 --tags_offset 0x100 --pagesize 4096 \
  --kernel "$kd" --ramdisk "$IMAGES_DIR/ramdisk.img" --cmdline "$cmdline" -o "$BOOT_IMG"
echo "cmdline: $cmdline"
ls -l "$BOOT_IMG"
