#!/bin/bash
# Install OH on slot B of a OnePlus 6, keeping Android on slot A (its boot, system, vendor, dtbo and userdata
# are not touched). Run it with the phone booted into Android from slot A with root adb (`adb root` works).
#   1. saves boot_a/b, dtbo_a/b, vbmeta_a/b to $BACKUP_DIR
#   2. writes system.img -> system_b (sda14) and vendor.img -> vendor_b (sde44) with dd from Android, verifies them
#   3. in fastboot: erases dtbo_b and makes slot B active (then run 11-boot-oh.sh)
# Re-run after every rebuild. fastboot.exe on Windows runs out of memory on the 2.5 GB system image, and
# hand-made sparse images were accepted but not written, which is why the images go through adb.
set -euo pipefail
. "$(dirname "$0")/config.sh"
sys="$IMAGES_DIR/system.img"; ven="$IMAGES_DIR/vendor.img"
[ -s "$sys" ] && [ -s "$ven" ] || die "build the images first (05-build-oh.sh)"
sh_() { adb_ shell "$@" | tr -d '\r'; }

step "checking the phone (Android, slot A, root adb)"
adb_ root >/dev/null 2>&1 || true; sleep 3; adb_ wait-for-device
[ "$(sh_ id -u)" = 0 ] || die "adb is not root; enable rooted debugging (e.g. LineageOS) so 'adb root' works"
[ "$(sh_ getprop ro.boot.slot_suffix)" = _a ] || die "Android must be running from slot A"
dev=$(sh_ getprop ro.product.device); case "$dev" in enchilada|OnePlus6) ;; *) die "not a OnePlus 6 (ro.product.device=$dev)";; esac
# The OH ramdisk mounts /dev/block/sda14 and /dev/block/sde44 (fstab.required): check the slot B mapping.
[ "$(sh_ readlink -f /dev/block/by-name/system_b)" = /dev/block/sda14 ] || die "system_b is not sda14"
[ "$(sh_ readlink -f /dev/block/by-name/vendor_b)" = /dev/block/sde44 ] || die "vendor_b is not sde44"
[ "$(sh_ blockdev --getsize64 /dev/block/sda14)" = "$SYSTEM_B_BYTES" ] || die "unexpected system_b size"
[ "$(sh_ blockdev --getsize64 /dev/block/sde44)" = "$VENDOR_B_BYTES" ] || die "unexpected vendor_b size"
[ "$(stat -c %s "$sys")" -le "$SYSTEM_B_BYTES" ] || die "system.img larger than system_b"

step "backups -> $BACKUP_DIR"
mkdir -p "$BACKUP_DIR"
for p in boot_a boot_b dtbo_a dtbo_b vbmeta_a vbmeta_b; do
  [ -s "$BACKUP_DIR/$p.img" ] && { echo "  $p.img exists, kept"; continue; }
  "$ADB" ${SERIAL:+-s "$SERIAL"} exec-out "dd if=/dev/block/by-name/$p bs=4194304 2>/dev/null" > "$BACKUP_DIR/$p.img"
  echo "  $p.img $(stat -c %s "$BACKUP_DIR/$p.img") bytes"
done
(cd "$BACKUP_DIR" && sha256sum ./*.img > SHA256SUMS)

write_part() {  # write_part IMAGE BLOCKDEV
  local img=$1 blk=$2 n bs=4194304
  n=$(stat -c %s "$img"); [ $((n % bs)) = 0 ] || bs=4096
  echo "  $(basename "$img") -> $blk ($n bytes)"
  "$ADB" ${SERIAL:+-s "$SERIAL"} exec-in "dd of=$blk bs=$bs" < "$img"
  sh_ sync
  local want have
  want=$(sha256sum < "$img" | cut -d' ' -f1)
  have=$(sh_ "dd if=$blk bs=$bs count=$((n / bs)) 2>/dev/null | sha256sum" | cut -d' ' -f1)
  [ "$want" = "$have" ] || die "verify failed for $blk ($have != $want)"
  echo "    verified sha256 $want"
}
step "writing slot B (system_b takes ~7 min over USB 2)"
write_part "$sys" /dev/block/sda14
write_part "$ven" /dev/block/sde44

step "fastboot: erase dtbo_b, slot B active"
# The bootloader overlays the slot's dtbo on whatever DTB it boots. Android's overlays do not fit the mainline
# DTB, and the boot is then silently dropped ("Booting OKAY" but the phone stays in fastboot).
adb_ reboot bootloader
wait_fastboot() { for _ in $(seq 1 90); do "$FASTBOOT" devices </dev/null 2>/dev/null | grep -q "${SERIAL:-fastboot}" && return 0; sleep 2; done; die "no fastboot device"; }
wait_fastboot
fastboot_ erase dtbo_b
fastboot_ --set-active=b
echo "done: the phone is in fastboot with slot B active; now run scripts/11-boot-oh.sh"
