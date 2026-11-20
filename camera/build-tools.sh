#!/bin/bash
# Static aarch64 media-ctl (v4l-utils), yavta and camss_setup for the phone, built with the OpenHarmony SDK's clang and musl
# sysroot of the synced tree (prebuilts/ohos-sdk, from 02-prebuilts.sh). They configure the camera's media graph
# and capture raw frames; neither is part of OpenHarmony. Output: $CAMERA_TOOLS_OUT/{media-ctl,yavta}.
set -euo pipefail
. "$(dirname "$0")/../scripts/config.sh"
SDK=$(ls -d "$OH_ROOT"/prebuilts/ohos-sdk/linux/*/native | tail -1)
[ -x "$SDK/llvm/bin/clang" ] || die "OH SDK native toolchain not found under $OH_ROOT/prebuilts/ohos-sdk"
SRC=${CAMERA_TOOLS_SRC:-$WORK_DIR/camera-tools/src}
OUT=${CAMERA_TOOLS_OUT:-$WORK_DIR/camera-tools/out}
V4L_UTILS_URL=https://github.com/gjasny/v4l-utils.git   # mirror of git.linuxtv.org/v4l-utils.git
V4L_UTILS_COMMIT=95ad25f6a77a0a6650f5f657ac2c5046efcd04a0
YAVTA_URL=https://git.ideasonboard.org/yavta.git
YAVTA_COMMIT=a6bb840d777a9a5aacce98112251aebd1b3e11f2
fetch() {  # fetch URL COMMIT DIR
  [ -d "$3/.git" ] || git clone -q "$1" "$3"
  git -C "$3" cat-file -e "$2^{commit}" 2>/dev/null || git -C "$3" fetch -q origin
  git -C "$3" checkout -q "$2"
}
mkdir -p "$SRC" "$OUT/gen"
fetch $V4L_UTILS_URL $V4L_UTILS_COMMIT "$SRC/v4l-utils"
fetch $YAVTA_URL $YAVTA_COMMIT "$SRC/yavta"
CC=("$SDK/llvm/bin/clang" --target=aarch64-linux-ohos --sysroot="$SDK/sysroot" -O2 -static -D_GNU_SOURCE -Wno-unused-result)
V=$SRC/v4l-utils
bash $V/utils/gen_media_bus_format_names.sh $V/include/linux/media-bus-format.h > "$OUT/gen/media-bus-format-names.h"
bash $V/utils/gen_media_bus_format_codes.sh $V/include/linux/media-bus-format.h > "$OUT/gen/media-bus-format-codes.h"
echo '#define PACKAGE_VERSION "v4l-utils-'${V4L_UTILS_COMMIT:0:12}'"' > "$OUT/gen/config.h"
"${CC[@]}" -include "$OUT/gen/config.h" -DGIT_COMMIT_CNT= -DGIT_SHA= -DGIT_COMMIT_DATE= -I"$OUT/gen" -I$V/include \
  -I$V/utils/media-ctl -I$V/utils/common -I$V/lib/include \
  $V/utils/media-ctl/media-ctl.c $V/utils/media-ctl/options.c $V/utils/media-ctl/libmediactl.c \
  $V/utils/media-ctl/libv4l2subdev.c -o "$OUT/media-ctl"
"${CC[@]}" -I"$SRC/yavta/include" "$SRC/yavta/yavta.c" -o "$OUT/yavta" -lm
# camss_setup: the boot-time graph setup of the OH camera patches (device/board/oneplus 0007), static, to try it
# on a RAM-booted phone before images are built (host-camera-test.sh verify-setup)
CS=$OH_ROOT/device/board/oneplus/fajita/camera/camss_setup/camss_setup.c
[ -f "$CS" ] || die "$CS missing (03-apply-patches.sh with patches/oh/device/board/oneplus/0007)"
"${CC[@]}" -Wall -Wextra "$CS" -o "$OUT/camss_setup"
"$SDK/llvm/bin/llvm-strip" "$OUT/media-ctl" "$OUT/yavta" "$OUT/camss_setup"
ls -l "$OUT/media-ctl" "$OUT/yavta" "$OUT/camss_setup"
