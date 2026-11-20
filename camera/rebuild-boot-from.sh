#!/bin/bash
# rebuild-boot-from.sh BOOT_IMG OUT_IMG [DTB]
# Make a camera RAM-boot image from any OnePlus 6 OH boot image (header v0, Image.gz + appended DTB): keep its
# kernel, ramdisk, command line and layout, replace only the appended DTB (default: the camera DTB that
# collect-test-files.sh put in $CAMERA_TEST_DIR). For a phone whose boot_b is not the build's boot image.
set -euo pipefail
in=${1:?boot image}; out=${2:?output image}
here=$(cd "$(dirname "$0")" && pwd)
. "$here/../scripts/config.sh"
dtb=${3:-${CAMERA_TEST_DIR:-$WORK_DIR/camera-test}/enchilada-cam.dtb}
MK=$HOST_DIR/mkbootimg
w=$(mktemp -d "$WORK_DIR/.rebuild.XXXXXX"); trap 'rm -rf "$w"' EXIT
python3 "$MK/unpack_bootimg.py" --boot_img "$in" --out "$w" > "$w/info.txt"
python3 - "$w/kernel" "$w/Image.gz" <<'PY'
import struct, sys
d = open(sys.argv[1], 'rb').read()
o = d.find(b'\xd0\x0d\xfe\xed')
while o >= 0:
    if o + struct.unpack('>I', d[o + 4:o + 8])[0] == len(d):
        break
    o = d.find(b'\xd0\x0d\xfe\xed', o + 1)
if o < 0 or d[:2] != b'\x1f\x8b':
    sys.exit('no Image.gz + appended DTB in this kernel blob')
open(sys.argv[2], 'wb').write(d[:o])
print('kernel Image.gz %d bytes, old DTB %d bytes' % (o, len(d) - o))
PY
cmdline=$(sed -n 's/^command line args: //p' "$w/info.txt")
cat "$w/Image.gz" "$dtb" > "$w/kernel-new"
python3 "$MK/mkbootimg.py" --header_version 0 --base 0 --kernel_offset 0x8000 --ramdisk_offset 0x1000000 \
  --second_offset 0xf00000 --tags_offset 0x100 --pagesize 4096 \
  --kernel "$w/kernel-new" --ramdisk "$w/ramdisk" --cmdline "$cmdline" -o "$out"
echo "cmdline: $cmdline"
ls -l "$out"
