#!/bin/bash
# RAM-boot OpenHarmony (fastboot boot of $BOOT_IMG with slot B active). Works from Android (adb), OH (hdc) or
# fastboot. Nothing is flashed; /data is a tmpfs, so every boot starts fresh (~45 s to install the system apps).
set -euo pipefail
. "$(dirname "$0")/config.sh"
[ -s "$BOOT_IMG" ] || die "$BOOT_IMG missing (06-make-boot.sh)"
in_fastboot() { "$FASTBOOT" devices </dev/null 2>/dev/null | grep -q "${SERIAL:-fastboot}"; }
wait_fastboot() { for _ in $(seq 1 90); do in_fastboot && return 0; sleep 2; done; die "no fastboot device"; }

if ! in_fastboot; then
  if "$ADB" devices </dev/null 2>/dev/null | tr -d '\r' | grep -q "${SERIAL:-.}[[:space:]]*device$"; then
    adb_ reboot bootloader
  elif "$HDC" list targets </dev/null 2>/dev/null | grep -q "$HDC_TARGET"; then
    hdc_ shell "reboot bootloader" || true
  else
    die "phone not found over adb, hdc or fastboot; hold Power + Volume Up for fastboot and let go when it shows"
  fi
fi
wait_fastboot
# A failed normal boot of slot B makes the bootloader fall back to slot A (whose dtbo blocks the OH kernel):
# select B every time, and start a fresh fastboot session (a second 'boot' in one session gives "Load Error").
fastboot_ --set-active=b
fastboot_ reboot-bootloader; sleep 4; wait_fastboot
[ "$(fastboot_ getvar current-slot 2>&1 | tr -d '\r' | sed -n 's/^current-slot: //p')" = b ] || die "slot B not active"
fastboot_ boot "$(tool_path "$FASTBOOT" "$BOOT_IMG")"

step "waiting for hdc ($HDC_TARGET)"
for _ in $(seq 1 90); do
  if "$HDC" list targets </dev/null 2>/dev/null | grep -q "$HDC_TARGET"; then
    hdc_ shell "param get const.ohos.fullname; uname -r" | tr -d '\r'
    echo "OpenHarmony is up; the launcher follows once bootevent.boot.completed=true"
    exit 0
  fi
  sleep 2
done
die "no hdc after 3 min: look at the phone screen (console=tty0 shows the boot log)"
