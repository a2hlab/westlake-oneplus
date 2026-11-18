#!/bin/bash
# tap.sh X Y: tap the screen at pixel X,Y through the touchscreen's input node, the way a finger does
# (the event goes through touchfwd into the app, like a real touch). For tests without a hand on the phone.
set -euo pipefail
. "$(dirname "$0")/config.sh"
wl_need WL_SC
x=${1:?usage: $0 X Y}; y=${2:?usage: $0 X Y}
bin=$WL_OUT/evtap
if [ ! -x "$bin" ] || [ "$WL_DIR/tools/evtap.c" -nt "$bin" ]; then
  t=$WL_SC/workspace/toolchains/ohos-sdk/native
  "$t/llvm/bin/clang" --target=aarch64-linux-ohos --sysroot="$t/sysroot" -O2 -o "$bin" "$WL_DIR/tools/evtap.c"
fi
if ! wl_hdc shell '[ -x /data/local/tmp/evtap ] && echo yes' | grep -q yes; then
  wl_hdc file send "$(wl_tool_path "$bin")" /data/local/tmp/evtap >/dev/null
  wl_hdc shell 'chmod 755 /data/local/tmp/evtap' >/dev/null
fi
# The touchscreen's raw range equals the screen in pixels (0..1079 x 0..2279), so X,Y go in unchanged.
wl_hdc shell "/data/local/tmp/evtap $WL_TOUCH_DEVICE $x $y" | tr -d '\r'
