#!/bin/bash
# test-kernel.sh OUT_DIR [PATCH...]: a kernel, or only a device tree, to try on the phone without new images or
# modules. Nothing is flashed: the result is RAM-booted, and a reset brings back what is installed.
#
#   1. Without PATCHes the kernel tree itself (KERNEL_SRC, as 03-apply-patches.sh left it) is built. With PATCHes it
#      is copied to OUT_DIR/linux and they are applied to the copy (in order; kernel patches as in patches/kernel).
#   2. Image.gz and the enchilada DTB are built into OUT_DIR/out with the configuration of the kernel on the phone
#      ($KERNEL_OUT/.config, from 04-build-kernel.sh) unchanged, so that the phone's modules still fit the kernel.
#      A PATCH that changes an option's value, or adds an option that is on, stops the script (CONFIG_CHANGE_OK=1:
#      build anyway); new options that stay off are fine.
#   3. OUT_DIR/boot-test.img: an installed boot image (TEST_BOOT_IMG, default $BOOT_IMG; header v0, Image.gz with
#      the DTB appended) with its ramdisk and command line kept and the new kernel and DTB.
#
#   DTB_ONLY=1   only the DTB is built; the boot image keeps its kernel (device-tree changes). Without PATCHes it
#                puts the device tree of the tree's applied patches into an older boot image: e.g. kernel 0011's
#                memory map into a boot image made before 0011 (2026-11-19).
#
# Then: BOOT_IMG=OUT_DIR/boot-test.img scripts/11-boot-oh.sh. KERNEL_SRC and KERNEL_OUT are only read. How the hang
# of 2026-11-19 was narrowed down with such kernels: docs/hang-2026-11-19.md.
set -euo pipefail
. "$(dirname "$0")/config.sh"
O=${1:?usage: $0 OUT_DIR [PATCH...]}; shift
: "${TEST_BOOT_IMG:=$BOOT_IMG}"
DTB=qcom/sdm845-oneplus-enchilada.dtb
mkb=$HOST_DIR/mkbootimg
[ -x "$OH_CLANG_BIN/clang" ] || die "OpenHarmony clang not found at $OH_CLANG_BIN (run 02-prebuilts.sh)"
[ -s "$KERNEL_OUT/.config" ] || die "$KERNEL_OUT/.config missing: the configuration of the phone's kernel (04-build-kernel.sh)"
[ -s "$TEST_BOOT_IMG" ] || die "$TEST_BOOT_IMG missing (TEST_BOOT_IMG: the boot image whose ramdisk and command line to keep)"
[ -f "$mkb/mkbootimg.py" ] || die "$mkb missing (06-make-boot.sh fetches it)"
patches=()
for p in "$@"; do [ -s "$p" ] || die "no patch $p"; patches+=("$(realpath "$p")"); done
TEST_BOOT_IMG=$(realpath "$TEST_BOOT_IMG")
mkdir -p "$O"; O=$(cd "$O" && pwd)
export PATH="$OH_CLANG_BIN:$PATH"

src=$KERNEL_SRC
if [ ${#patches[@]} -gt 0 ]; then
  step "kernel tree: a copy of $KERNEL_SRC with ${#patches[@]} patch(es)"
  src=$O/linux; rm -rf "$src"; mkdir -p "$src"
  tar -C "$KERNEL_SRC" --exclude=.git -cf - . | tar -C "$src" -xf -
  # The copy is a repository of its own, so that git apply never resolves paths against one around OUT_DIR.
  git -c init.defaultBranch=test -C "$src" init -q
  for p in "${patches[@]}"; do
    git -C "$src" apply --whitespace=nowarn "$p" || die "$p does not apply to $KERNEL_SRC"
    echo "  applied: $p"
  done
fi

B=$O/out; mkdir -p "$B"
# The same make command line as 04-build-kernel.sh.
K=(make -C "$src" O="$B" ARCH=arm64 LLVM=1 LLVM_IAS=1 CC=clang HOSTCC=clang LOCALVERSION=
   KBUILD_BUILD_USER=builder KBUILD_BUILD_HOST=oneplus6)
step "configuration: $KERNEL_OUT/.config"
cp "$KERNEL_OUT/.config" "$B/.config"
"${K[@]}" olddefconfig >/dev/null
set_options() { grep -v -e '^#' -e '^$' "$1" | sort; }
if cmp -s "$KERNEL_OUT/.config" "$B/.config"; then
  echo "  unchanged"
elif [ "$(set_options "$KERNEL_OUT/.config")" = "$(set_options "$B/.config")" ]; then
  echo "  the same options set (the patches add options; all stay off)"
else
  diff <(set_options "$KERNEL_OUT/.config") <(set_options "$B/.config") | head -20 || true
  [ "${CONFIG_CHANGE_OK:-0}" = 1 ] ||
    die "the patches change the kernel's configuration, so the phone's modules may not fit (CONFIG_CHANGE_OK=1: build anyway)"
fi
if [ "${DTB_ONLY:-0}" = 1 ]; then targets=("$DTB"); else targets=(Image.gz "$DTB"); fi
step "build: ${targets[*]} (log: $O/build.log)"
"${K[@]}" -j"$(nproc)" "${targets[@]}" > "$O/build.log" 2>&1 || { tail -20 "$O/build.log"; die "the build failed"; }
if [ "${DTB_ONLY:-0}" != 1 ]; then
  rel=$(cat "$B/include/config/kernel.release")
  [ "$rel" = "$KERNEL_RELEASE" ] || die "kernel release $rel, not $KERNEL_RELEASE: the phone's modules would not load"
fi
dtb=$O/$(basename "$DTB"); cp "$B/arch/arm64/boot/dts/$DTB" "$dtb"

step "boot image: $TEST_BOOT_IMG with the new $([ "${DTB_ONLY:-0}" = 1 ] && echo DTB || echo "kernel and DTB")"
u=$O/boot-unpacked; rm -rf "$u"; mkdir -p "$u"
python3 "$mkb/unpack_bootimg.py" --boot_img "$TEST_BOOT_IMG" --out "$u" > "$u/info.txt"
cmdline=$(sed -n 's/^command line args: //p' "$u/info.txt")$(sed -n 's/^additional command line args: //p' "$u/info.txt")
[ -n "$cmdline" ] || die "no command line in $TEST_BOOT_IMG"
if [ "${DTB_ONLY:-0}" = 1 ]; then
  # The kernel blob is Image.gz with a DTB appended: the DTB is the flattened tree whose size reaches the blob's end.
  python3 - "$u/kernel" "$u/Image.gz" <<'PY'
import struct, sys
d = open(sys.argv[1], 'rb').read()
o = d.find(b'\xd0\x0d\xfe\xed')
while o >= 0 and (o + 8 > len(d) or o + struct.unpack('>I', d[o + 4:o + 8])[0] != len(d)):
    o = d.find(b'\xd0\x0d\xfe\xed', o + 1)
if o < 0 or d[:2] != b'\x1f\x8b':
    sys.exit('not an Image.gz with an appended DTB: ' + sys.argv[1])
open(sys.argv[2], 'wb').write(d[:o])
print('  kept: Image.gz, %d bytes (old DTB %d bytes)' % (o, len(d) - o))
PY
  img=$u/Image.gz
else
  img=$B/arch/arm64/boot/Image.gz
fi
cat "$img" "$dtb" > "$u/kernel-dtb"
# The layout of 06-make-boot.sh.
python3 "$mkb/mkbootimg.py" --header_version 0 --base 0 --kernel_offset 0x8000 --ramdisk_offset 0x1000000 \
  --second_offset 0xf00000 --tags_offset 0x100 --pagesize 4096 \
  --kernel "$u/kernel-dtb" --ramdisk "$u/ramdisk" --cmdline "$cmdline" -o "$O/boot-test.img"
echo "cmdline: $cmdline"
(cd "$O" && sha256sum boot-test.img "$(basename "$dtb")")
echo "RAM-boot it (nothing is flashed): BOOT_IMG=$O/boot-test.img $SCRIPTS_DIR/11-boot-oh.sh"
