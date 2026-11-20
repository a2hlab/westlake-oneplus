# A second phone

How a second OnePlus 6 was brought to the same state as the first (2026-11-20): OH 7.0 installed over 6.1, its own
hdc serial, `/data` on the whole of its storage, enterprise Wi-Fi. Westlake on it, and a corpus round shared by both
phones, are in `westlake/README.md` on `main` ("Two phones").

## Every phone on these images has the same hdc serial

The board's USB init config (`device/board/oneplus/fajita/cfg/init.fajita.usb.cfg`, installed in `vendor.img` as
`/etc/init.fajita.usb.cfg`) writes a fixed serial number into the USB gadget, and hdc takes the gadget's serial as
the device's key (`HDC_TARGET` in `scripts/config.sh` is that value). Two phones on these images are one hdc target:
`hdc list targets` shows one entry, and `hdc -t <key>` sends each command to either phone. A round, a flash script or
a reboot can then land on the wrong phone. Windows names the second phone's USB device with a generated instance id
(`USB\VID_2207&PID_5000\6&...`) because its serial is taken.

Before acting on a phone, check which one answers: `param get ohos.boot.sn` is the bootloader's serial, different on
every phone (it prints a trailing space; the phone's shell has no `tr`, so trim with `${sn%% *}`).

**Until the next boot**, a phone can get another serial: unbind the gadget, write the serial, bind again. hdc loses
the phone while it is unbound, so run it detached on the phone, and check the boot serial in the same script so that
it never changes the other phone:

```sh
# on the phone, e.g. as /data/local/tmp/usbserial.sh <boot serial> <new serial>, run with: setsid sh usbserial.sh A B
want=$1; new=$2; g=/config/usb_gadget/g1
sn=$(param get ohos.boot.sn); sn=${sn%% *}
[ "$sn" = "$want" ] || { echo "boot serial $sn, not $want: nothing changed"; exit 0; }
udc=$(cat $g/UDC)
( sleep 2; echo "" > $g/UDC; sleep 1; echo "$new" > $g/strings/0x409/serialnumber; sleep 1; echo "$udc" > $g/UDC ) \
  </dev/null >/dev/null 2>&1 &
```

**In the image, for one phone**: flash that phone a copy of `vendor.img` whose serial line names its own serial. The
line occurs once in the image file; replace it with bytes of the same length (here the new serial is shorter, so the
JSON line ends in spaces after its comma, outside the string), and the file keeps its size, inode and SELinux label:

```sh
cp images/vendor.img images-phone2/vendor.img
python3 - images-phone2/vendor.img <<'EOF'
import sys
p = sys.argv[1]; data = bytearray(open(p, 'rb').read())
old = b'<IMAGE SERIAL>",'; new = b'<NEW SERIAL>",'.ljust(len(old))   # same length
assert data.count(old) == 1 and len(new) == len(old)
i = data.find(old); data[i:i + len(old)] = new; open(p, 'wb').write(data)
EOF
debugfs -R "cat /etc/init.fajita.usb.cfg" images-phone2/vendor.img | python3 -c 'import json, sys; json.load(sys.stdin); print("json ok")'
debugfs -R "ea_list /etc/init.fajita.usb.cfg" images-phone2/vendor.img   # security.selinux still set
```

The proper fix (not made yet) is in the board patch: write a value of the phone's own, as the `fajita_mini` config
does (it copies the UFS device's `wwid` into the serial number), and rebuild the vendor image.

After two phones shared the serial, hdc's session for it can stay `Offline` when one of them leaves it. Unplug that
phone's cable and plug it in again. Restarting the hdc server would also work, but it drops every other device's
session, and Windows' `pnputil /restart-device` asks for a reboot before it takes effect.

## OH 7.0 on another phone

`scripts/15-flash.sh` (system_b, vendor_b, then `13-flash-boot.sh`: boot_b, slot B active and marked successful)
installs the images; for a second phone, name it in every setting:

```sh
SERIAL=<its fastboot serial> HDC_TARGET=<its hdc serial, now and after the flash> \
FASTBOOT=<a Linux fastboot> IMAGES_DIR=images-phone2 BOOT_IMG=<boot image> BACKUP_DIR=<a directory with a boot_b.img> \
  scripts/15-flash.sh
```

- With the vendor image above, `HDC_TARGET` is the phone's own serial: `13-flash-boot.sh` waits for it after the
  reboot, then marks slot B over hdc.
- From OH the scripts send `reboot bootloader` over hdc (`HDC_TARGET`). On WSL the phone in fastboot is `18d1:d00d`
  in `usbipd list`: bind and attach that busid only (never another device: a D600 board is `18d1:5000`), make its
  node writable (`wsl.exe -u root chmod a+rw /dev/bus/usb/BUS/DEV`), and check that `fastboot devices` lists this
  phone's serial before anything is written. The attachment ends when the phone reboots, and hdc finds it again.
- `13-flash-boot.sh` stops when `BACKUP_DIR` has no `boot_b.img` (its undo copy, saved by `10-install.sh`). A phone
  set up some other way has none; any copy passes the check, but it is not that phone's undo.
- `BOOT_IMG`: the boot image with the reserved-memory fix (kernel `0011`), as on the first phone.
- Times: system 106 s, vendor 31 s, boot 1 s, then about a minute until OH has booted.
- A phone whose `/data` was still the RAM disk has nothing to carry over.

## `/data` on the whole storage

`scripts/14-data-partition.sh --erase-android-data` splits Android's `userdata` into a smaller `userdata` and
`ohdata`. `ANDROID_GB=1` leaves Android 1 GiB, the least the script handles (0 is not supported: its arithmetic needs
a partition there), and gives OH the rest: 108 GiB of a 110 GiB `userdata` on a 128 GB phone. It reboots twice and
saves the partition table to `BACKUP_DIR`, so give each phone its own:

```sh
SERIAL=<fastboot serial> HDC_TARGET=<hdc serial> BACKUP_DIR=<this phone's backups> ANDROID_GB=1 \
  scripts/14-data-partition.sh --erase-android-data
```

Android's data is gone; Android itself (slot A) stays.

## Enterprise Wi-Fi (PEAP) with uitest

Settings → WLAN, switch it on, then the network. What makes it work from a script (`uitest dumpLayout` to find
things, `uitest uiInput click X Y` to tap them):

- The network list re-sorts while it scans: read a row's position right before tapping it, and check the dialog's
  title before typing anything.
- The dialog is a secure window: screenshots are black, `uitest dumpLayout -i` shows it.
- While the password field has the focus, Back only toggles the keyboard, and a tap outside does not close the
  dialog: to leave a wrong dialog, `aa force-stop com.ohos.settings` and start again.
- The CA certificate selector opens only when its row is clear of the floating Connect button: scroll the dialog's
  list (`uinput -T -m 540 1000 540 650 600`) until the row is in the middle, then tap it and choose
  **Do not validate**.
- Type the identity last: changing the EAP method or the CA setting clears it.
- Secrets never go on a command line: write each into a RAM-backed file on the PC, `hdc file send` it, type it with
  `uitest uiInput inputText X Y "$(cat FILE)"` (hdcd logs the command, not the value), and delete the file on both
  sides. The identity is plain text in `dumpLayout` output (the password field is masked): delete every dump.

With `/data` on `ohdata` the login stays across reboots.
