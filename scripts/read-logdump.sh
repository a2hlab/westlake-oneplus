#!/bin/bash
# Read the boot log OH wrote with op6.logdump=1 (BOOT_CMDLINE_EXTRA=op6.logdump=1 06-make-boot.sh) after a hang:
# force-restart the phone (hold Power ~10 s), let it fall back to Android, then run this (root adb).
set -euo pipefail
. "$(dirname "$0")/config.sh"
adb_ root >/dev/null 2>&1 || true; sleep 3; adb_ wait-for-device
out="$WORK_DIR/logdump-$(date +%Y%m%d-%H%M%S).txt"
"$ADB" ${SERIAL:+-s "$SERIAL"} exec-out "dd if=/dev/block/by-name/system_b bs=4096 skip=655360 count=1024 2>/dev/null" \
  | python3 -c '
import sys
d = sys.stdin.buffer.read().split(b"\0", 1)[0].decode("utf-8", "replace")
end = d.find("=== END")   # the newest dump starts at offset 0; anything after its END marker is stale
sys.stdout.write(d[:d.find("\n", end) + 1] if end >= 0 else d)' > "$out"
echo "saved $out ($(wc -l < "$out") lines)"; head -1 "$out"
