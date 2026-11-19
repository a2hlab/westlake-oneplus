#!/bin/bash
# Give OH a /data that survives reboots. Splits the phone's userdata partition (Android's, the last one on its disk)
# into a smaller userdata for Android (ANDROID_GB, default 32) and "ohdata" (the rest, ext4). The board's
# mount-data.sh (patch device/board/oneplus 0003, in the vendor image) mounts ohdata on /data at every boot.
#
# THIS ERASES ANDROID'S DATA. Android formats its smaller userdata at its next boot and starts as a new phone
# (setup, USB debugging and rooted debugging need to be turned on again on the phone itself). Run 13-flash-boot.sh
# first: until Android is set up again, the phone has no root adb, and OH has to start without it.
#
#   scripts/14-data-partition.sh --erase-android-data     (OH running, hdc; about 2 minutes, two reboots)
#
# The partition table before the change is saved to $BACKUP_DIR/gpt-<disk>-before-ohdata.bin.
# Undo: hdc shell "sgdisk --load-backup=<that file, sent back to the phone> /dev/block/<disk>", reboot; Android then
# formats userdata again (its data is gone either way).
set -euo pipefail
. "$(dirname "$0")/config.sh"
[ "${1:-}" = --erase-android-data ] || die "this erases Android's data (userdata); run it with --erase-android-data"
: "${ANDROID_GB:=32}"
sh_() { hdc_ shell "$@" | tr -d '\r'; }
booted() { [ "$(sh_ 'param get bootevent.boot.completed' | tr -d '[:space:]')" = true ]; }   # it prints "true "
in_oh() { "$HDC" list targets </dev/null 2>/dev/null | grep -q "$HDC_TARGET"; }
wait_oh() {   # after a reboot: hdc, then boot completion
  sleep 15
  for _ in $(seq 1 90); do in_oh && break; sleep 2; done
  in_oh || die "no hdc after the reboot: look at the phone screen"
  for _ in $(seq 1 60); do booted && return 0; sleep 5; done
  die "OH did not finish booting"
}
in_oh || die "OH is not running (no hdc target $HDC_TARGET)"
sh_ 'ls /vendor/etc/mount-data.sh' | grep -q '^/vendor/etc/mount-data.sh$' \
  || die "this vendor image has no mount-data.sh (patch device/board/oneplus 0003): build and install current images"

step "partition table"
if [ -n "$(sh_ 'ls /dev/block/by-name/ohdata 2>/dev/null')" ]; then
  sh_ 'mount' | grep -q ' /data type ext4' && { echo "ohdata exists and /data is on it: nothing to do"; exit 0; }
  die "an ohdata partition exists but /data is not on it: look at it by hand (dmesg | grep mount-data)"
fi
u=$(sh_ 'readlink -f /dev/block/by-name/userdata'); name=${u##*/}
[[ "$name" =~ ^(sd[a-z])([0-9]+)$ ]] || die "userdata is $u; expected /dev/block/sdXN"
disk=/dev/block/${BASH_REMATCH[1]}; num=${BASH_REMATCH[2]}
ss=$(sh_ "cat /sys/block/${disk##*/}/queue/logical_block_size")
info=$(sh_ "sgdisk -i $num $disk")
first=$(sed -n 's/^First sector: \([0-9]*\).*/\1/p' <<< "$info"); last=$(sed -n 's/^Last sector: \([0-9]*\).*/\1/p' <<< "$info")
type=$(sed -n 's/^Partition GUID code: \([0-9A-F-]*\).*/\1/p' <<< "$info")
guid=$(sed -n 's/^Partition unique GUID: \([0-9A-F-]*\).*/\1/p' <<< "$info")
nparts=$(sh_ "sgdisk -p $disk" | awk '$1 ~ /^[0-9]+$/ {n=$1} END {print n}')
[ -n "$first" ] && [ -n "$last" ] && [ -n "$type" ] && [ -n "$guid" ] && [ -n "$ss" ] || die "could not read userdata ($disk $num)"
[ "$num" = "$nparts" ] || die "userdata ($num) is not the last partition on $disk ($nparts): not handled"
mib=$((1048576 / ss))
a_last=$((first + ANDROID_GB * 1073741824 / ss - 1))
o_first=$(( (a_last + 1 + mib - 1) / mib * mib ))   # 1 MiB aligned
a_last=$((o_first - 1))
o_gib=$(( (last - o_first + 1) * ss / 1073741824 ))
(( o_gib >= 8 )) || die "ANDROID_GB=$ANDROID_GB leaves OH only $o_gib GiB"
o=$((num + 1))
echo "  $disk: userdata $num $first-$last ($(( (last - first + 1) * ss / 1073741824 )) GiB, ${ss}-byte sectors)"
echo "  ->  userdata $num $first-$a_last ($ANDROID_GB GiB, erased)   ohdata $o $o_first-$last ($o_gib GiB)"
new="-a 1 -d $num -n $num:$first:$a_last -c $num:userdata -t $num:$type -u $num:$guid -n $o:$o_first:$last -c $o:ohdata -t $o:8300"

step "saving the partition table -> $BACKUP_DIR"
mkdir -p "$BACKUP_DIR"; save="$BACKUP_DIR/gpt-${disk##*/}-before-ohdata.bin"
sh_ "sgdisk --backup=/data/local/tmp/gpt-before-ohdata.bin $disk" | tail -1
hdc_ file recv /data/local/tmp/gpt-before-ohdata.bin "$(tool_path "$HDC" "$save")" >/dev/null
[ "$(stat -c %s "$save" 2>/dev/null || echo 0)" -gt 1024 ] || die "could not save the partition table to $save"

step "writing it (pretend first)"
sh_ "sgdisk -P $new -p $disk" | tail -3
sh_ "sgdisk $new $disk" | tail -1
chk=$(sh_ "sgdisk -i $o $disk")
grep -q "Partition name: 'ohdata'" <<< "$chk" && grep -q "First sector: $o_first " <<< "$chk" || die "the new table is not as planned"
# The kernel keeps the old table until the reboot, and the old userdata node starts where both new ones do:
# erase the start of Android's file system (so that Android formats userdata at its next boot) and of ohdata.
sh_ "dd if=/dev/zero of=$u bs=$ss count=$((16 * mib)) 2>/dev/null; dd if=/dev/zero of=$u bs=$ss seek=$((o_first - first)) count=$((16 * mib)) 2>/dev/null; sync"
sh_ 'reboot' || true
wait_oh

step "ext4 on ohdata"
od=$(sh_ 'readlink -f /dev/block/by-name/ohdata')
[ "$od" = "$disk$o" ] || die "no ohdata after the reboot (by-name/ohdata -> '$od')"
# orphan_file (mke2fs 1.47's default) needs kernel 5.15; this kernel is 5.10
sh_ "mke2fs -t ext4 -L ohdata -m 1 -O ^orphan_file -E lazy_itable_init=0,lazy_journal_init=0 $od >/dev/null 2>&1 || mke2fs -t ext4 -L ohdata -m 1 -E lazy_itable_init=0,lazy_journal_init=0 $od >/dev/null 2>&1; e2fsck -n -f $od 2>&1 | tail -1"
sh_ 'reboot' || true
wait_oh
sh_ 'mount' | grep " /data type ext4" | grep -q "^$od " || die "/data is not on $od after the reboot (dmesg | grep mount-data)"
sh_ 'df -h /data | tail -1'
echo "/data is $od ($o_gib GiB) and survives reboots. Set up again what lived on the RAM disk (e.g. Wi-Fi) once."
