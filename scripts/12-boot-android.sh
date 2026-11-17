#!/bin/bash
# Back to Android on slot A (untouched by the install). Works from OH (hdc) or fastboot.
set -euo pipefail
. "$(dirname "$0")/config.sh"
in_fastboot() { "$FASTBOOT" devices </dev/null 2>/dev/null | grep -q "${SERIAL:-fastboot}"; }
if ! in_fastboot; then
  if "$HDC" list targets </dev/null 2>/dev/null | grep -q "$HDC_TARGET"; then
    hdc_ shell "reboot bootloader" || true
  else
    die "phone not in OH (hdc) or fastboot; hold Power + Volume Up for fastboot"
  fi
fi
for _ in $(seq 1 90); do in_fastboot && break; sleep 2; done
in_fastboot || die "no fastboot device"
fastboot_ --set-active=a
fastboot_ reboot
echo "rebooting into Android (slot A)"
