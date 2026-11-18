# OpenHarmony 6.1 on the OnePlus 6: bring-up notes

How the OnePlus 6 (enchilada) went from "OH 6.1 tree" to "launcher on screen", failure by failure. Each item
says how the problem showed, what the cause was and what fixed it; the fixes are the patches and scripts of
this repository.

## Route

Options looked at:
- **OH in a chroot on top of Android:** the phone's Android kernel (4.9) has none of the drivers OH needs
  (binder access-token extensions, access_tokenid, hilog, ...), and Android's SurfaceFlinger owns the display.
- **Halium / libhybris** (Oniro `hybris_generic`): runs OH on Android kernels through Android HALs, but only for
  Volla MediaTek phones, and the OnePlus 6 Halium image (Halium 9, kernel 4.9) is too old.
- **Mainline kernel + OH userspace:** the community port at [gitee.com/ohos_port](https://gitee.com/ohos_port)
  for the OnePlus 6T (fajita). Chosen.

The port: `device_board_oneplus` and `device_soc_qualcomm` have `OpenHarmony-6.1-LTS` branches (DRM/KMS composer,
Mesa 25.0.1 freedreno, qrtr/rmtfs/pd-mapper/tqftpserv), `vendor_oneplus`, `linux-sdm845`, `alsa-plugins` and
`third_party_eudev` only go up to `OpenHarmony-5.1-Release`. `linux-sdm845` at 5.1-Release is 5.10.194 with the OH
kernel extensions and already contains `sdm845-oneplus-enchilada.dts`. The 6.1-LTS board config was written for
a 6.6.101 kernel that is not published, so this build combines the 6.1-LTS board with the 5.10.194 kernel.

The OnePlus 6 and 6T share the A/B partition layout the port uses: `system_b` = `sda14` (2,998,927,360 bytes)
and `vendor_b` = `sde44` (1 GiB), which the ramdisk's `fstab.required` mounts as `/usr` and `/vendor`.
OH is put on slot B only and RAM-booted, so Android on slot A keeps working.

## Building

| Symptom | Cause | Fix |
|---|---|---|
| `repo sync` fails with HTTP 418 from gitcode.com | gitcode rejects git's user agent; repo forces `GIT_HTTP_USER_AGENT` | browser `User-Agent` as `http.https://gitcode.com/.extraHeader` (`01-sync.sh`) |
| `third_party/eudev` missing | not in the OH manifest, the port needs it | `third_party_eudev` from ohos_port in `manifests/ohport.xml` |
| host tools: `'uint8_t' was not declared` | GCC 13 (Ubuntu 24.04) headers no longer include `<cstdint>` transitively | `patches/oh/build`, `patches/oh/arkcompiler/ets_runtime` |
| SDK build: npm/lru-cache errors | OH 6.1 expects Node 14 but its SDK build's npm needs a newer Node | `nodejs/current` -> Node 18 (`02-prebuilts.sh`), `EXPECTED_NODE_VERSION` in `build.sh` (`03-apply-patches.sh`) |
| `strip.native.min.js` missing (jsframework) | `rollup-plugin-typescript2` breaks under Node 18 | jsframework's `gen_snapshot` pinned to Node 14 (`patches/oh/third_party/jsframework`) |
| ruby `OpenStruct` / python errors | a conda environment on `PATH` | clean `PATH` in `05-build-oh.sh` |
| mingw clang: `libtinfo.so.5` not found | Ubuntu 24.04 dropped libtinfo5; a symlink to `.so.6` fails (versioned symbols) | Ubuntu 22.04 `libtinfo5` package extracted to `$HOST_DIR/lib` (`00-host-setup.sh`) |
| libnl `install.sh` aborts in `patch` | autoconf 2.72 words `config.h` differently, the config.h hunks miss | `patches/oh/third_party/libnl` |
| gn: `init_feature_loader` unknown, part `rust_libc` not found, CFI sanitize assert | the port's product config is for 5.1 | `patches/oh/vendor/oneplus`, `--gn-args allow_sanitize_debug=true` |
| wifi: `HalDeviceManager` undeclared | `wifi_feature_with_hdi_chip_supported = false` no longer builds in 6.1 | feature removed (`patches/oh/vendor/oneplus`) |
| build killed (out of memory) | ArkUI compiles take 1-2 GB each; hb's `--jobs` is ignored | `--ninja-args=-j6` (`JOBS`) |
| clean build only: `'v1_2/display_composer_type.h' file not found` (`display_composer_vdi_impl.cpp`) | the sdm845 display libraries include generated IDL headers (v1.1-v1.3) but depend only on the v1.0 header targets, so a clean parallel build can compile them before the headers exist | header-only IDL dependencies (`patches/oh/device/soc/qualcomm`) |
| `'make modules_install' requires depmod`; `modules.dep` missing | minimal Ubuntu installs (e.g. the `ubuntu:24.04` image) have no `kmod` | `kmod` in `00-host-setup.sh` |
| build exits 1 after all images are written | post-build `deps_guard` dependency-policy check (Passthrough rules) | `--deps-guard false` |

## Booting the kernel

1. **Windows does not see the phone in fastboot.** No driver binds to `USB\VID_18D1&PID_D00D`. Google's USB
   driver has the right "Android Bootloader Interface" model but does not list this ID:
   `scripts/windows/install-fastboot-driver.ps1` binds it (as Device Manager > Have Disk would).
2. **Writing `system_b`.** `fastboot.exe` (Windows, platform-tools 36.0.2) dies with `std::bad_alloc` on the
   2.5 GB image, also with `-S 256M`. Hand-made Android sparse images were accepted ("Writing OKAY" in 0.001 s)
   but nothing was written: a check of the partition found the old content. Writing from Android over root adb
   (`adb exec-in dd`) works and is verified by SHA-256 (`10-install.sh`, about 7 minutes).
3. **"Booting OKAY" and nothing happens.** `fastboot boot` reports success, but the phone stays in fastboot and
   never leaves USB. The stock Android boot image boots fine through `fastboot boot`, so the bootloader works.
   Adding the msm-id/board-id the bootloader reports (read from the stock device tree) did not help. Cause: the
   bootloader lays the active slot's `dtbo` partition over whatever DTB it boots, and Android's overlays do not
   fit the mainline DTB. **Fix:** make slot B active and erase `dtbo_b` (backed up first). Slot A keeps its dtbo.
4. **"Load Error"** on a second `fastboot boot` in the same fastboot session after a dropped boot:
   `fastboot reboot-bootloader` first (`11-boot-oh.sh` always does).
5. **Back to slot A.** A failed normal boot of slot B (for example after a forced restart) makes the bootloader
   mark B unbootable and fall back to A, whose dtbo blocks the OH kernel again: select B before every boot.
6. **Power + Volume Up.** Holding Power after the fastboot screen appears restarts the phone again in the middle
   of the next command ("Status read failed (Too many links)"). Release the keys as soon as fastboot shows, or
   use `adb reboot bootloader` / `hdc shell reboot bootloader`.

## Bringing up OH userspace

1. **No hdc.** The kernel runs (penguins on screen), OH boots, but the phone never appears on USB. The 6.1-LTS
   board config writes `a600000.usb` into the gadget's `UDC`, the controller's name under 6.6. On 5.10 the
   dwc3 node is `dwc3@a600000`, so the controller is `a600000.dwc3`. Renaming the node instead is not an option
   on 5.10: `dwc3-qcom` looks its child up by the name `dwc3`. Fix in `init.fajita.usb.cfg`.
2. **The kernel panics about 40 s in.** With `console=tty0` the screen showed init stopping every service,
   unmounting `/vendor` and `/data`, then `sysrq: Trigger a crash`, init's reaction to a "critical" service
   crashing too often. Earlier in the log: `SAMGR: CanRequest callingTkid:3044, tokenType:0` and
   `AddSystemAbilityInner PERMISSION DENIED`. 3044 is `hdf_devmgr`'s UID: when a caller's access token is 0,
   OH's binder code reports the UID instead (`binder_invoker.cpp`), so every native service had token 0.
   Cause: `/etc/init.cfg` (system) runs `mkdir /data/service/el0/access_token` and `load_access_token_id` in its
   `pre-init` job, before the vendor `pre-init` commands where our tmpfs is mounted on `/data`. The token
   file could not be created on the read-only root, and the tmpfs then hid the empty directory. Fix: the vendor
   config repeats the `/data` setup and `load_access_token_id` right after mounting the tmpfs.
3. **Stuck on the boot animation.** hdc works now: `bootevent.bms.main.bundles.ready=false`, the bundle manager
   logs `GetRdbStore failed, errCode:27394118` for every system app, and `InitHapToken failed`. 27394118 is
   `E_CONFIG_INVALID_CHANGE`, which RdbStore returns when `SecurityLabel::SetSecurityLabel()` fails: OH tags
   every database file with the `user.security` xattr, and tmpfs only supports `user.*` xattrs from Linux 6.6.
   Fix: `patches/kernel/0001-shmem-user-xattrs.patch` (the same handler upstream added). After it: 45 apps
   installed, `bootevent.boot.completed=true`, launcher on screen.
4. **hdc disappears after a while.** When the screen times out OH auto-suspends, and suspend makes dwc3 drop
   the USB connection (the port's `USB_NOTES.md`, issue B1). Fix: no suspend action on screen timeout
   (`power_suspend.json`, the port's "route 1"); the power key still suspends.

## Debugging techniques that worked

- **Screen console:** `console=tty0` plus the Terminus 16x32 font makes the kernel and init log readable on the
  1080x2280 panel. Penguins in the top-left corner mean the kernel is up and the display driver works.
  `BOOT_CMDLINE_EXTRA=ignore_loglevel` shows every message; a phone photo of the last screen was enough to find
  item 2 above.
- **Log dump to `system_b`:** with `op6.logdump=1`, a small service writes dmesg, `ps`, mounts and native crash
  dumps every 4 s past the end of the OH system image inside `system_b`; Android reads it back after a hang
  (`scripts/read-logdump.sh`). Useful when the system dies before hdc comes up.
- **Keeping the system up:** init panics the kernel when a service marked `"critical"` crashes too often.
  During bring-up, setting those flags to `[0, ...]` in the system image's cfg files kept OH alive long enough to
  look around. The images this repository builds keep the stock flags.
- **ramoops does not help here:** the OH and Android kernels use the same ramoops region (0xac300000, 4 MB), but
  no record survives a reboot on this phone, not even Android to Android.
- **WSL + Windows tools:** a long-running WSL shell can hold a dead interop socket (`UtilAcceptVsock ... accept4
  failed 110`; every `.exe` call fails). Point `WSL_INTEROP` at a `/run/WSL/*_interop` socket that answers
  (not necessarily the newest one); `config.sh` tests them and picks a live one.
