#!/bin/bash
# Install the images with fastboot alone: system_b and vendor_b, then boot_b through 13-flash-boot.sh (which also
# makes slot B active and marks it booted). For a phone whose Android has no root adb any more (after
# 14-data-partition.sh) or that no longer runs Android; 10-install.sh needs root adb. Works from OH (hdc) or fastboot.
#
# fastboot flashes in 256 MB sparse chunks (-S), so it never holds the 2.5 GB system image at once. The Windows
# fastboot.exe still ran out of memory on it (see 10-install.sh): on WSL use a Linux fastboot (Android platform-tools
# for Linux) with the phone's fastboot device given to WSL by usbipd-win, from an administrator prompt:
#   usbipd list                                   (the phone in fastboot mode is 18d1:d00d)
#   usbipd bind --busid <BUSID>; usbipd attach --wsl --busid <BUSID>
# and FASTBOOT=<linux fastboot>. The attachment ends when the phone restarts, so OH's hdc reaches Windows again.
set -euo pipefail
. "$(dirname "$0")/config.sh"
sys="$IMAGES_DIR/system.img"; ven="$IMAGES_DIR/vendor.img"
for f in "$sys" "$ven" "$BOOT_IMG"; do [ -s "$f" ] || die "$f missing (05-build-oh.sh, 06-make-boot.sh, or 09-get-images.sh)"; done
in_fastboot() { "$FASTBOOT" devices </dev/null 2>/dev/null | grep -q "${SERIAL:-fastboot}"; }
if ! in_fastboot; then
  if "$HDC" list targets </dev/null 2>/dev/null | grep -q "$HDC_TARGET"; then
    hdc_ shell "reboot bootloader" || true
  elif "$ADB" devices </dev/null 2>/dev/null | tr -d '\r' | grep -q "${SERIAL:-.}[[:space:]]*device$"; then
    adb_ reboot bootloader
  else
    die "phone not found over hdc, adb or fastboot; hold Power + Volume Up for fastboot and let go when it shows"
  fi
fi
for _ in $(seq 1 90); do in_fastboot && break; sleep 2; done
in_fastboot || die "no fastboot device (on WSL: attach it with usbipd, see the top of this script)"
step "system_b <- $sys"
fastboot_ -S 256M flash system_b "$(tool_path "$FASTBOOT" "$sys")"
step "vendor_b <- $ven"
fastboot_ -S 256M flash vendor_b "$(tool_path "$FASTBOOT" "$ven")"
step "boot_b, slot B (13-flash-boot.sh)"
exec "$(dirname "$0")/13-flash-boot.sh"
