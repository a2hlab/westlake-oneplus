#!/bin/bash
# Gather what the on-phone camera test needs into $CAMERA_TEST_DIR (default $WORK_DIR/camera-test): the camera
# modules from the kernel build (04-build-kernel.sh with patches/kernel/0005-0007), media-ctl and yavta
# (build-tools.sh), the phone scripts, and a RAM-boot image (06-make-boot.sh: this kernel + DTB, the OH ramdisk).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/../scripts/config.sh"
A=${CAMERA_TEST_DIR:-$WORK_DIR/camera-test}
T=${CAMERA_TOOLS_OUT:-$WORK_DIR/camera-tools/out}
mkdir -p "$A"
for m in drivers/media/platform/qcom/camss/qcom-camss.ko drivers/media/v4l2-core/v4l2-cci.ko \
         drivers/media/i2c/imx376.ko drivers/media/i2c/imx371.ko drivers/media/i2c/imx519.ko drivers/media/i2c/lc89821x.ko; do
  [ -s "$KERNEL_OUT/$m" ] || die "$KERNEL_OUT/$m missing (patches/kernel/0005-0007 applied? 04-build-kernel.sh run?)"
  cp "$KERNEL_OUT/$m" "$A/"
done
for t in media-ctl yavta camss_setup; do [ -x "$T/$t" ] || die "$T/$t missing (run camera/build-tools.sh)"; cp "$T/$t" "$A/"; done
cp "$here/cam-load.sh" "$here/cam-capture.sh" "$here/cam-verify-setup.sh" "$A/"
cp "$KERNEL_OUT/arch/arm64/boot/dts/qcom/sdm845-oneplus-enchilada.dtb" "$A/enchilada-cam.dtb"
BOOT_IMG="$A/boot-oneplus6-camera.img" "$here/../scripts/06-make-boot.sh"
(cd "$A" && sha256sum boot-oneplus6-camera.img enchilada-cam.dtb *.ko media-ctl yavta camss_setup cam-*.sh > SHA256SUMS)
echo "test files in $A"
