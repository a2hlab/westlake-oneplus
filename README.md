# westlake-oneplus

OpenHarmony 6.1 on the **OnePlus 6** (`enchilada`, SDM845): everything needed to build the same images we run and
put them on a phone (or to install the [prebuilt images](#install-without-building)), as the base for running
[Westlake](https://github.com/a2hlab/westlake) (Android apps on OpenHarmony) on OnePlus hardware.

It builds OpenHarmony **6.1.0.31** (tag `OpenHarmony-v6.1-Release`, API 23) for the community OnePlus 6T port
([gitee.com/ohos_port](https://gitee.com/ohos_port), product `fajita`) and adapts it to the OnePlus 6 with a
5.10.194 kernel. OH lives on **slot B only**. Android on slot A (and its data) stays as it is, and OH is
RAM-booted from the PC (`fastboot boot`), so the boot partitions are never flashed.

## Status (2026-11-18)

| | |
|---|---|
| Boots to the OH launcher, touch input works | yes |
| Display (DRM/KMS composer, Mesa freedreno on the Adreno 630) | yes |
| `hdc` over USB (shell, file transfer, screenshots, `reboot bootloader`) | yes |
| `bootevent.boot.completed`, 45 system apps installed, launcher + SystemUI running | yes |
| Wi-Fi: Settings > WLAN switches on and lists the networks in range | yes, since release `v6.1.0.31-r2` (r1 predates the fix); joining a network not tested yet |
| Bluetooth | no: the Bluetooth driver host needs a vendor `libbt_vendor.z.so`, which the port does not have |
| audio | no: the kernel has no sound card |
| power key: display off and on | yes, with the kernel kept out of suspend: its suspend (s2idle) drops USB and loops; built into images after `v6.1.0.31-r2`, a one-line step on r2 (known limitations) |
| modem, camera, sensors | not checked yet |

How this was verified (2026-11-17):
- Applying the port's patches and ours to the pinned commits gives exactly the files of the tested tree (checked
  per project, blob by blob).
- From a clean clone of this repository, `01-sync.sh` brings all 505 projects to the pinned commits, and
  `02-prebuilts.sh` and `03-apply-patches.sh` apply every patch cleanly.
- Images built by `04`-`06`, installed by `10-install.sh` and started by `11-boot-oh.sh` reach the launcher;
  `check-oh.sh` reports OpenHarmony-6.1.0.31, kernel 5.10.194-sdm845, `bootevent.boot.completed=true`,
  45 apps installed, launcher and SystemUI running.
- From-scratch builds (empty `out/` and ccache) found two gaps that an incremental tree never shows, both fixed
  here: a missing build-order dependency in the port's display driver (a clean parallel build failed with
  `'v1_2/display_composer_type.h' file not found`, see [`device/soc/qualcomm`](patches/oh/device/soc/qualcomm)),
  and `kmod` (`depmod`) missing on minimal Ubuntu installs (`00-host-setup.sh`).
- With those fixes, a full build of the fresh clone's tree (`04`-`06`, empty `out/` and ccache) in a clean
  `ubuntu:24.04` container on a 72-thread server took about 2 hours, and its images, installed by
  `10-install.sh` and started by `11-boot-oh.sh`, reach the launcher: `check-oh.sh` reports OpenHarmony-6.1.0.31,
  boot completed 37 s after the RAM boot, 45 apps installed, launcher and SystemUI running.

Known limitations:
- `/data` is a RAM disk (tmpfs). Nothing persists across reboots and every boot is a first boot (about 45 s
  of system-app installation before the launcher appears). The phone's own `userdata` stays Android's.
- OH is started from a PC each time (`fastboot boot`). `12-boot-android.sh` goes back to Android; a plain
  reboot gets there too, but only after slot B (left active by the install) fails to boot and the bootloader
  falls back to slot A.
- Avoid Android system updates while you use OH: A/B updates (e.g. LineageOS) install to the inactive slot B,
  which replaces OH and leaves Android on slot B, where `10-install.sh` will not install.
- The device reports itself as "Oneplus 6T" / model "Fajita" (strings of the port it is based on).
- The kernel never suspends. Its suspend (s2idle) disconnects USB, and with it hdc, and it loops: the modem
  (`1e40000.ipa`) wakes the kernel every few seconds and OH suspends it again, so after the power key the screen did
  not stay on. The board's `init.fajita.cfg` holds the kernel wake lock `no_suspend` from boot, which OH's suspend
  loop (power_host) waits on; the power key still turns the display off and on, the screen timeout turns it off.
  OH's suspend on screen timeout is turned off as well (vendor patch). The images of release `v6.1.0.31-r2` predate
  the wake lock: on them, take it after each boot with `hdc shell "echo no_suspend > /sys/power/wake_lock"`
  (`westlake/03-prep.sh` does). If the phone is already looping, hold the power key for 10-15 s and boot OH again
  (`11-boot-oh.sh`).

## What you need

- A OnePlus 6 with an **unlocked bootloader**, running Android from **slot A** with **root adb** (`adb root`
  works, e.g. LineageOS with rooted debugging). The install writes slot B from that Android.
- To build the images yourself, a build host: x86_64 Linux (Ubuntu 22.04 or 24.04, also a minimal `ubuntu:24.04`
  container; WSL2 works) with **~300 GB** free disk and about **2 GB of RAM per build job** (`JOBS`, default 6:
  fits in 24 GB; 64 jobs ran in 138 GB). A finished build uses about 200 GB (88 GB sources, 96 GB `out/`, 17 GB
  ccache; the ccache can grow to 100 GB over rebuilds). A full build takes about 2 hours with 64 jobs on a
  72-thread server, and over 8 hours with 6 jobs on a 16-core laptop.
- `adb` and `fastboot` (Android platform-tools) and `hdc` (from an OpenHarmony SDK, `toolchains/hdc`).
  On WSL with the Windows tools, point `ADB`, `FASTBOOT` and `HDC` at the `.exe` files: the scripts hand them
  `\\wsl.localhost\...` paths, so images stay on the Linux disk. Windows also needs a driver for the phone's
  fastboot mode: [`scripts/windows/install-fastboot-driver.ps1`](scripts/windows/install-fastboot-driver.ps1).

## Install without building

Each [release](https://github.com/a2hlab/westlake-oneplus/releases) has the images built from this repository:
`system.img` and `vendor.img` (zstd-compressed), `boot-oneplus6.img` and `SHA256SUMS`. No build host is needed,
only the phone and tools above plus `curl`, `zstd` and `sha256sum`:

```sh
git clone https://github.com/a2hlab/westlake-oneplus && cd westlake-oneplus
scripts/09-get-images.sh    # latest release -> ~/oh61-oneplus6/prebuilt: download, check, unpack
export IMAGES_DIR=~/oh61-oneplus6/prebuilt BOOT_IMG=~/oh61-oneplus6/prebuilt/boot-oneplus6.img
scripts/10-install.sh && scripts/11-boot-oh.sh && scripts/check-oh.sh
```

`RELEASE_TAG=<tag>` picks another release. The rest (booting again, going back to Android, undoing the
install) is the same as for self-built images, see [Install and boot](#install-and-boot).

## Build

```sh
git clone https://github.com/a2hlab/westlake-oneplus && cd westlake-oneplus
sudo scripts/00-host-setup.sh && scripts/00-host-setup.sh   # packages; then libtinfo5 + repo launcher
scripts/01-sync.sh          # OH 6.1 release tag + the port repos at the tested commits (~100 GB download)
scripts/02-prebuilts.sh     # OH prebuilts; Node 18 as "current"
scripts/03-apply-patches.sh # the port's patches, ours, the kernel's (re-runnable)
scripts/04-build-kernel.sh  # 5.10.194 kernel + enchilada DTB; modules into the board directory
scripts/05-build-oh.sh      # system.img, vendor.img, ramdisk.img (hours)
scripts/06-make-boot.sh     # boot image (kernel + DTB + OH ramdisk)
```

Settings are in [`scripts/config.sh`](scripts/config.sh): `WORK_DIR` (default `~/oh61-oneplus6`), `JOBS`,
tool paths, phone serial. Put your own values in `scripts/local.sh` (git-ignored).
`scripts/verify-pins.sh` checks that all 505 projects of the tree are at the commits listed in
[`manifests/oh61-full-pinned.xml`](manifests/oh61-full-pinned.xml).

## Install and boot

```sh
scripts/10-install.sh       # phone in Android (slot A), root adb: backs up the boot/dtbo/vbmeta partitions,
                            # writes system_b + vendor_b, erases dtbo_b, makes slot B active
scripts/11-boot-oh.sh       # RAM-boots OH from fastboot, Android or OH; waits for hdc
scripts/check-oh.sh         # version, boot completion, apps, launcher/SystemUI, screenshot
scripts/12-boot-android.sh  # back to Android on slot A
```

`11-boot-oh.sh` ends when hdc answers (about 30 s); the launcher follows once the system apps are installed.
Then for example `hdc shell`, `hdc shell snapshot_display -f /data/local/tmp/s.jpeg` and
`hdc file recv /data/local/tmp/s.jpeg`. Re-run `10-install.sh` after rebuilding the images.

**Undo:** `12-boot-android.sh` returns to Android. Slot A is never written. To give slot B back to Android,
flash the saved `dtbo_b.img` (`fastboot flash dtbo_b phone-backup/dtbo_b.img`) and let an Android update or a
flash rewrite `system_b`/`vendor_b`.

## Android apps with Westlake

[westlake/](westlake/README.md) runs Android apps on this build with [Westlake](https://github.com/a2hlab/westlake): Fossify Clock opens over the host app's window and takes taps on the touchscreen. Five scripts: the phone's runtime pieces (GPU stand-in, firmware list), the window bridge for OH's classic window manager, and per boot the phone tools, the framework and the app.

## What the patches change

| Patch | Why |
|---|---|
| [`device/board/oneplus`](patches/oh/device/board/oneplus) | 5.10.194 modules; `/data` on tmpfs with the token setup redone after the mount (otherwise every native service has access token 0, samgr rejects them all and init panics the kernel); USB controller `a600000.dwc3` (the 6.6 name `a600000.usb` leaves hdc without USB); optional log dumper |
| [`vendor/oneplus`](patches/oh/vendor/oneplus) | parts OH 6.1 needs in the fajita product config; drop two features 6.1 rejects; Wi-Fi as on rk3568 (nl80211 driver client, default chip HAL, chip driver service); no auto-suspend on screen timeout |
| [`foundation/communication/wifi`](patches/oh/foundation/communication/wifi) | scan results: the beacon P2P element was read past the end of the probe-response buffer (crashed the Wi-Fi service on 7.0) |
| [`device/soc/qualcomm`](patches/oh/device/soc/qualcomm) | the display HDI libraries wait for the IDL headers they include (v1.1-v1.3); without it a clean build can fail with `'v1_2/display_composer_type.h' file not found` |
| [`kernel/0001`](patches/kernel/0001-shmem-user-xattrs.patch) | `user.*` xattrs on tmpfs (upstream since 6.6): OH's databases set `user.security`; without it no app installs and the phone sits on the boot animation |
| [`kernel/0002`, `0003`](patches/kernel) | OnePlus 6 msm-id/board-id in the DTB; ramoops without ECC (bring-up leftovers) |
| [`kernel/oneplus6.config`](patches/kernel/oneplus6.config) | Terminus 16x32 console font for the on-screen boot log |
| [`build`](patches/oh/build), [`arkcompiler/ets_runtime`](patches/oh/arkcompiler/ets_runtime) | host tools vs GCC 13 headers (Ubuntu 24.04) |
| [`third_party/jsframework`](patches/oh/third_party/jsframework), [`third_party/libnl`](patches/oh/third_party/libnl) | Node 14 for one tool while the build uses Node 18; autoconf 2.72 |

Each patch file starts with its rationale. [`docs/bringup-notes.md`](docs/bringup-notes.md) has the full
bring-up record: every failure, how it showed and what fixed it.

## Debugging a boot

- The boot log is on the phone screen (`console=tty0`, large font). `BOOT_CMDLINE_EXTRA=ignore_loglevel
  scripts/06-make-boot.sh` shows every message.
- `BOOT_CMDLINE_EXTRA=op6.logdump=1 scripts/06-make-boot.sh` makes OH write its kernel log, process list and
  crash dumps every 4 s to the unused end of `system_b`. After a hang, force-restart (Power ~10 s; the phone
  falls back to Android) and run `scripts/read-logdump.sh`. ramoops does not survive a reboot on this phone.
- `hdc shell reboot bootloader` takes a running OH back to fastboot.

## Layout

```
manifests/ohport.xml            port repos pinned to the tested commits (repo local manifest)
manifests/oh61-full-pinned.xml  every project of the tested tree with its commit
patches/oh/<project path>/      patches for OpenHarmony projects
patches/kernel/                 kernel patches + config fragment
scripts/                        host setup, sync, build, install, boot (00..12), helpers
westlake/                       Android apps with Westlake on this build (01..05, tap.sh)
docs/bringup-notes.md           how it was brought up, failure by failure
```

## Credits and licenses

Built on [OpenHarmony](https://gitee.com/openharmony) (Apache-2.0), the OnePlus 6T community port at
[gitee.com/ohos_port](https://gitee.com/ohos_port), the Linux kernel (GPL-2.0, the kernel patches are under the
kernel's license) and AOSP `mkbootimg`. The patches here follow the licenses of the projects they apply to.
