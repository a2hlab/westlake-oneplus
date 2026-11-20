#!/bin/bash
# fetch-images.sh DIR: the images of a build made on another machine (BUILD_HOST, over ssh), ready to install.
# system.img, vendor.img and ramdisk.img are copied into DIR and checked against the build machine's sha256; then
# DIR/boot-oneplus6.img is made from the kernel and DTB of an existing boot image (KERNEL_BOOT_IMG: the kernel rarely
# changes when OH does), the new ramdisk and this checkout's command line. Install with 10-install.sh or 15-flash.sh
# (IMAGES_DIR=DIR BOOT_IMG=DIR/boot-oneplus6.img).
#   BUILD_HOST        the build machine as ssh knows it (e.g. a Host entry of BUILD_SSH_CONFIG)
#   BUILD_SSH_CONFIG  an ssh config file (optional)
#   BUILD_IMAGES_DIR  the images directory there (default: $IMAGES_DIR, i.e. the same layout as here)
#   KERNEL_BOOT_IMG   the boot image whose kernel and DTB are kept (default $BOOT_IMG)
set -euo pipefail
. "$(dirname "$0")/config.sh"
D=${1:?usage: $0 DIR}
: "${BUILD_HOST:?set BUILD_HOST: the build machine as ssh knows it}"
: "${BUILD_IMAGES_DIR:=$IMAGES_DIR}"
: "${KERNEL_BOOT_IMG:=$BOOT_IMG}"
ssh_=(ssh ${BUILD_SSH_CONFIG:+-F "$BUILD_SSH_CONFIG"}); scp_=(scp -q ${BUILD_SSH_CONFIG:+-F "$BUILD_SSH_CONFIG"})
mk=$HOST_DIR/mkbootimg
[ -f "$mk/mkbootimg.py" ] || die "$mk missing (06-make-boot.sh fetches it)"
[ -s "$KERNEL_BOOT_IMG" ] || die "$KERNEL_BOOT_IMG missing (KERNEL_BOOT_IMG: a boot image whose kernel to keep)"
mkdir -p "$D"

step "images from $BUILD_HOST:$BUILD_IMAGES_DIR"
for f in system.img vendor.img ramdisk.img; do
  timeout 3600 "${scp_[@]}" "$BUILD_HOST:$BUILD_IMAGES_DIR/$f" "$D/$f" </dev/null
done
timeout 300 "${ssh_[@]}" "$BUILD_HOST" "cd '$BUILD_IMAGES_DIR' && sha256sum system.img vendor.img ramdisk.img" \
  </dev/null > "$D/SHA256SUMS.build"
(cd "$D" && sha256sum -c SHA256SUMS.build)

step "boot image: the kernel and DTB of $KERNEL_BOOT_IMG, the new ramdisk"
u=$(mktemp -d); trap 'rm -rf "$u"' EXIT
python3 "$mk/unpack_bootimg.py" --boot_img "$KERNEL_BOOT_IMG" --out "$u" >/dev/null
cmdline="$BOOT_CMDLINE_BASE${BOOT_CMDLINE_EXTRA:+ $BOOT_CMDLINE_EXTRA}"
python3 "$mk/mkbootimg.py" --header_version 0 --base 0 --kernel_offset 0x8000 --ramdisk_offset 0x1000000 \
  --second_offset 0xf00000 --tags_offset 0x100 --pagesize 4096 \
  --kernel "$u/kernel" --ramdisk "$D/ramdisk.img" --cmdline "$cmdline" -o "$D/boot-oneplus6.img"
echo "cmdline: $cmdline"
ls -l "$D"
