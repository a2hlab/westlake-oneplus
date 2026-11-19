#!/bin/bash
# Make OH start on its own: write $BOOT_IMG to boot_b, select slot B and, once OH has booted, mark slot B as
# booted successfully (as Android's boot control does), so that every later boot - a reboot, a reset after a hang,
# a battery pull - starts OH without the PC. Works from Android (adb), OH (hdc) or fastboot.
# Android on slot A is not touched: 12-boot-android.sh still goes back to it (and 11-boot-oh.sh still RAM-boots).
# Without the success mark the bootloader counts down slot B's tries on every boot and then falls back to slot A.
# Undo: fastboot flash boot_b "$BACKUP_DIR/boot_b.img" (saved by 10-install.sh), then 12-boot-android.sh.
set -euo pipefail
. "$(dirname "$0")/config.sh"
[ -s "$BOOT_IMG" ] || die "$BOOT_IMG missing (06-make-boot.sh)"
[ -s "$BACKUP_DIR/boot_b.img" ] || die "no $BACKUP_DIR/boot_b.img: run 10-install.sh first (it saves boot_b)"
in_fastboot() { "$FASTBOOT" devices </dev/null 2>/dev/null | grep -q "${SERIAL:-fastboot}"; }
wait_fastboot() { for _ in $(seq 1 90); do in_fastboot && return 0; sleep 2; done; die "no fastboot device"; }
in_oh() { "$HDC" list targets </dev/null 2>/dev/null | grep -q "$HDC_TARGET"; }
sh_() { hdc_ shell "$@" | tr -d '\r'; }
booted() { [ "$(sh_ 'param get bootevent.boot.completed' | tr -d '[:space:]')" = true ]; }   # it prints "true "
if ! in_fastboot; then
  if "$ADB" devices </dev/null 2>/dev/null | tr -d '\r' | grep -q "${SERIAL:-.}[[:space:]]*device$"; then
    adb_ reboot bootloader
  elif in_oh; then
    hdc_ shell "reboot bootloader" || true
  else
    die "phone not found over adb, hdc or fastboot; hold Power + Volume Up for fastboot and let go when it shows"
  fi
fi
wait_fastboot
step "boot_b <- $BOOT_IMG"
# erase first: what flash does not overwrite of Android's boot image (its AVB footer at the partition's end) goes
fastboot_ erase boot_b
fastboot_ flash boot_b "$(tool_path "$FASTBOOT" "$BOOT_IMG")"
fastboot_ --set-active=b
fastboot_ reboot
step "waiting for OH (hdc $HDC_TARGET)"
for _ in $(seq 1 90); do in_oh && break; sleep 2; done
in_oh || die "no hdc after 3 min: look at the phone screen"
for _ in $(seq 1 60); do booted && break; sleep 5; done
booted || die "OH did not finish booting; slot B stays unmarked"
cmdline=$(sh_ 'cat /proc/cmdline')
case "$cmdline" in *androidboot.slot_suffix=_b*) ;; *) die "OH did not start from slot B; slot B stays unmarked" ;; esac
# a RAM boot (fastboot boot) says androidboot.mode=fastboot
case "$cmdline" in *androidboot.mode=normal*) ;; *) die "OH was not started from boot_b; slot B stays unmarked" ;; esac
step "marking slot B successful"
# Qualcomm keeps the A/B state in the GPT attributes of the boot_a/boot_b entries: bits 48-49 priority, 50 active,
# 51-53 tries left, 54 successful, 55 unbootable (QcomModulePkg PartitionTableUpdate.h)
# (one line: hdc shell mangles multi-line commands)
attr=$(sh_ 'p=$(readlink -f /dev/block/by-name/boot_b); n=${p##*/}; num=$(cat /sys/class/block/$n/partition); disk=/dev/block/$(basename $(readlink -f /sys/class/block/$n/..)); sgdisk -A $num:set:54 $disk >/dev/null && sgdisk -i $num $disk' \
  | sed -n 's/^Attribute flags: //p')
echo "  boot_b attributes: $attr"
[[ "$attr" =~ ^[0-9A-Fa-f]{16}$ ]] || die "could not read boot_b's attributes"
ab=$((16#${attr:2:2}))   # bits 48-55
(( (ab & 0x44) == 0x44 && (ab & 0x80) == 0 )) || die "slot B is not marked active + successful"
echo "OH now starts by itself (slot B). 12-boot-android.sh goes back to Android; this script makes OH the default again."
