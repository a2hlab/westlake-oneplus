# westlake-oneplus

OpenHarmony 6.1 on the **OnePlus 6** (`enchilada`, SDM845): everything needed to build the same images we run and
put them on a phone (or to install the [prebuilt images](#install-without-building)), as the base for running
[Westlake](https://github.com/a2hlab/westlake) (Android apps on OpenHarmony) on OnePlus hardware.

It builds OpenHarmony **6.1.0.31** (tag `OpenHarmony-v6.1-Release`, API 23) for the community OnePlus 6T port
([gitee.com/ohos_port](https://gitee.com/ohos_port), product `fajita`) and adapts it to the OnePlus 6 with a
5.10.194 kernel. OH lives on **slot B only**. Android on slot A (and its data) stays as it is, and OH is
RAM-booted from the PC (`fastboot boot`), so the boot partitions are never flashed. Optionally
([Persistent OH](#persistent-oh-optional)), OH starts by itself from boot_b and keeps `/data` on a partition of
its own, at the cost of Android's data.

## OpenHarmony 7.0 (this branch, `oh-7.0`)

This branch builds **OpenHarmony 7.0.0.38** (tag `OpenHarmony-v7.0-Release`) for the same phone, with
**SceneBoard**, the window manager OpenHarmony and HarmonyOS phones use (the 6.1 branch runs OH's classic window
manager). Verified on 2026-11-18: built on a 64-thread server; the images (slot B, same install and boot steps as
6.1) boot in about 25 s to SceneBoard's lock screen; a swipe unlocks it to the home and app screens. Westlake runs
Android apps on it as OH applications (its managed launch): see `westlake/README.md` on the `main` branch.
Unlock a minute or so after boot: an unlock while the system is still starting can block SceneBoard for 6 s
(`THREAD_BLOCK_6S`), and OH then restarts it.

How SceneBoard is enabled (all in `patches/oh/vendor/oneplus`, as the 7.0 tree's own SceneBoard product
`vendor/revoview/wukong100` does): `window_manager_use_sceneboard`, which makes `applications/standard/hap` install
the prebuilt SceneBoard and its system apps; their preinstall entries; RenderService's uni-render. Three traps
each kept the phone from showing anything:

| symptom | cause |
|---|---|
| stays at the boot logo | the port's capability list names other signing fingerprints for `com.ohos.sceneboard` than the prebuilt's, so BMS refuses its privileged extensions and installs nothing; in SceneBoard mode the classic launcher and SystemUI are disabled, so no home screen starts |
| black screen | RenderService in divided render (the port's default): SceneBoard's UI contexts get no task runner and attach nothing to the display |
| lock screen or home screen frozen, phone reboots | SceneBoard's calls into `audio_server` block (no sound card); after 6 s OH kills and restarts SceneBoard, again and again. The board config stops `audio_server` at boot |

Checked on the phone with 7.0 + SceneBoard:

| | |
|---|---|
| SceneBoard lock screen, unlock, home and app screens | yes |
| CPU frequency scaling (schedutil, up to 1.77 / 2.65 GHz) | yes: the board patch loads `icc_osm_l3`; without it the CPU frequency driver waited for it forever (6.1 too) |
| Wi-Fi: Settings > WLAN switches on and lists the networks in range | yes |
| enterprise Wi-Fi (802.1X/EAP) | yes: Settings shows the EAP login (method, phase 2, CA certificate, identity, password), and a corporate network (WPA-EAP, PEAP) connected with an address and internet |
| Android apps through Westlake (managed launch) | yes: Fossify Clock as an OH application, with OH's input, keyboard and BACK |
| Bluetooth | yes: Settings turns it on, the phone is visible and discovers. The port had no vendor `libbt_vendor.z.so` for the driver host; `device/soc/qualcomm/0003` adds one that gives OH's stack the kernel's HCI user channel on hci0 (the kernel's `hci_qca` drives the WCN3990) |
| audio | no sound yet: the sound card registers ("sdm845 - OnePlus 6") once the OnePlus 6's speaker amplifier driver is loaded (`snd_soc_max98927`, board `0004`; the port's list is the 6T's, with a TFA98xx); OH's audio stack is not set up for this card (no ALSA adapter configuration, a template route file), so `audio_server` stays stopped at boot |
| GPU | stable: the gralloc pads buffers to 16 rows (`device/soc/qualcomm/0002`); before, Mesa's 16x4 tile resolves wrote past buffers of odd heights (IOMMU faults, CP illegal instruction, hangs) |
| suspend | the kernel is kept out of it by the board's wake lock (held after boot, no suspends) |
| modem, camera, sensors | not checked yet |

Settings in `scripts/local.sh`:

```sh
OH_MANIFEST_URL=https://gitcode.com/openharmony/manifest.git   # 7.0 is on gitcode, not gitee
OH_TAG=OpenHarmony-v7.0-Release
SKIP_PIN_CHECK=1        # the 6.1 pin list does not apply; manifests/oh70-full-pinned.xml has every 7.0 commit
```

What 7.0 needs on top of the 6.1 port:

| | fix |
|---|---|
| port patches | 7 of the port's 18 OH patches rebased onto 7.0 (`patches/port-7.0`, used in place of the port's copies) |
| product parts | `drivers_adapter` renamed `drivers_devhost`; `qrcodegen` replaced by `qrcode_generator`; `expat` and `vma` added (`patches/oh/vendor/oneplus`) |
| board | the `alsa-utils` group target is gone; its five tools are listed by name |
| prebuilts | declgen's npm postinstall clones TypeScript master from gitcode: pointed at the pinned in-tree copy (`02-prebuilts.sh`) |
| SDK | the new Cortex-M lite NDK stub did not link (musl crt unwind tables) |
| taihe | its wheel takes the version from git and cannot parse the release tag (`SETUPTOOLS_SCM_PRETEND_VERSION`) |
| hdc, updater | two account/updater-mode switches were tied to SELinux, which this port turns off |
| libnl | already pre-configured in 7.0; the 6.1 autoconf patch is dropped |
| Wi-Fi | without the chip driver service, which the port never declared, 7.0's Wi-Fi service crashed at every start and took Settings with it: the nl80211 driver client, the default chip HAL and the chip service, as on rk3568 (`patches/oh/vendor/oneplus`); plus a scan-result read past the end of a buffer (`patches/oh/foundation/communication/wifi`) |
| Settings | the port's own Settings 1.0.0 (`default_app_config`) replaced the 7.0 prebuilt and has no enterprise Wi-Fi pages: dropped, so the prebuilt installs (`patches/oh/vendor/oneplus`) |
| user unlock | hmdfs cannot be mounted on `/data`, a RAM disk here; the storage daemon then fails to start user 100, which is never unlocked, and SceneBoard refuses to start any app that is not a system app (`ERR_BLOCK_START_FIRST_BOOT_SCREEN_UNLOCK`): `const.distributed_file_property.enabled=false` (`patches/oh/vendor/oneplus`) |
| window decoration | on in the port's window config: off, as wukong100 (`patches/oh/vendor/oneplus`). Native OH apps such as Settings still draw ArkUI's title row with window buttons; the cause is not found yet (Westlake's apps have none) |

gitcode's web firewall answered git clones with HTTP 418 on 2026-11-18 (after the sync for this branch
finished), from two networks; a sync may have to wait for that to clear.

## Status (2026-11-17)

| | |
|---|---|
| Boots to the OH launcher, touch input works | yes |
| Display (DRM/KMS composer, Mesa freedreno on the Adreno 630) | yes |
| `hdc` over USB (shell, file transfer, screenshots, `reboot bootloader`) | yes |
| `bootevent.boot.completed`, 45 system apps installed, launcher + SystemUI running | yes |
| Wi-Fi, Bluetooth, audio, modem, camera, sensors, suspend/resume | not checked yet |

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
- `/data` is a RAM disk (tmpfs) unless OH has a partition of its own ([Persistent OH](#persistent-oh-optional)).
  Nothing persists across reboots and every boot is a first boot (about 45 s of system-app installation before
  the launcher appears). The phone's own `userdata` stays Android's.
- OH is started from a PC each time (`fastboot boot`), unless `13-flash-boot.sh` made it the phone's default. `12-boot-android.sh` goes back to Android; a plain
  reboot gets there too, but only after slot B (left active by the install) fails to boot and the bootloader
  falls back to slot A.
- Avoid Android system updates while you use OH: A/B updates (e.g. LineageOS) install to the inactive slot B,
  which replaces OH and leaves Android on slot B, where `10-install.sh` will not install.
- The device reports itself as "Oneplus 6T" / model "Fajita" (strings of the port it is based on).
- The kernel never suspends. Its suspend (s2idle) disconnects USB, and with it hdc, and it loops (seen on 6.1, same
  kernel): the modem (`1e40000.ipa`) wakes the kernel every few seconds and OH suspends it again, so after the power
  key the screen did not stay on. The board's `init.fajita.cfg` holds the kernel wake lock `no_suspend` from boot,
  which OH's suspend loop (power_host) waits on; the power key still turns the display off and on. OH's suspend on
  screen timeout is turned off as well (vendor patch). Images built before this change lack the wake lock: on them,
  take it after each boot with `hdc shell "echo no_suspend > /sys/power/wake_lock"`.

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

## Persistent OH (optional)

By default OH leaves the phone as it was: only slot B's system and vendor are written, OH is RAM-booted from the
PC and `/data` is a RAM disk. Two scripts make OH the phone's own system instead (verified with OH 7.0 on
2026-11-18):

```sh
scripts/13-flash-boot.sh                            # boot_b <- the OH boot image; slot B active, marked successful
scripts/14-data-partition.sh --erase-android-data   # userdata -> Android (ANDROID_GB, default 32) + ohdata (ext4)
```

- `13-flash-boot.sh` writes `$BOOT_IMG` to boot_b and, once OH is up, marks slot B as booted successfully (as
  Android's boot control does; without the mark the bootloader counts down slot B's tries and falls back to slot
  A). A reboot, a reset or a recovery from a hang then starts OH without the PC. Android on slot A stays as it is:
  `12-boot-android.sh` still goes back to it, and `13-flash-boot.sh` makes OH the default again. Undo:
  `fastboot flash boot_b phone-backup/boot_b.img`.
- `14-data-partition.sh` **erases Android's data**. It splits `userdata` (the last partition on its disk) into a
  smaller `userdata`, which Android formats at its next boot (Android then starts like a new phone: setup, USB
  debugging and rooted debugging need the phone's screen), and `ohdata`, which the board's `mount-data.sh`
  mounts on `/data` at every boot (patch `device/board/oneplus/0003`; without the partition `/data` stays a RAM
  disk, so the same images work either way). Run `13-flash-boot.sh` first: once Android's data is gone it has no
  root adb until someone sets it up again, and OH has to start by itself. The partition table before the split is
  saved to `phone-backup/`.
- Then the Wi-Fi login, the installed apps and everything else on `/data` survive reboots. The first boot on the
  new partition is a first boot as usual; `mount-data.sh` checks the file system (`e2fsck`) at every boot, since a
  hang ends in a hard reset.

## What the patches change

| Patch | Why |
|---|---|
| [`device/board/oneplus`](patches/oh/device/board/oneplus) | 5.10.194 modules; `/data` on tmpfs with the token setup redone after the mount (otherwise every native service has access token 0, samgr rejects them all and init panics the kernel); USB controller `a600000.dwc3` (the 6.6 name `a600000.usb` leaves hdc without USB); optional log dumper; the kernel wake lock `no_suspend`; `icc_osm_l3` so the CPU frequency driver probes; with SceneBoard, `audio_server` stopped at boot (no sound card); `/data` on the `ohdata` partition when the phone has one (`0003`, see [Persistent OH](#persistent-oh-optional)) |
| [`vendor/oneplus`](patches/oh/vendor/oneplus) | parts OH 6.1 needs in the fajita product config; drop two features 6.1 rejects; Wi-Fi as on rk3568 (nl80211 driver client, default chip HAL, chip driver service); no auto-suspend on screen timeout; English (United States) as the default language (`0002`; OH's default is Chinese); SceneBoard as wukong100 (window manager feature, preinstall entries, the prebuilt's signing fingerprint, settings files) and RenderService uni-render |
| [`foundation/communication/wifi`](patches/oh/foundation/communication/wifi) | scan results: the beacon P2P element was read past the end of the probe-response buffer (crashed the Wi-Fi service on 7.0) |
| [`device/soc/qualcomm`](patches/oh/device/soc/qualcomm) | the display HDI libraries wait for the IDL headers they include (v1.1-v1.3); without it a clean build can fail with `'v1_2/display_composer_type.h' file not found`. The gralloc pads buffers to 16 rows: Mesa's GPU resolves 16x4 pixel blocks past the end of buffers whose height is not a multiple of 4 (IOMMU faults, CP illegal instruction, hangs) |
| [`kernel/0001`](patches/kernel/0001-shmem-user-xattrs.patch) | `user.*` xattrs on tmpfs (upstream since 6.6): OH's databases set `user.security`; without it no app installs and the phone sits on the boot animation |
| [`kernel/0002`, `0003`](patches/kernel) | OnePlus 6 msm-id/board-id in the DTB; ramoops without ECC (bring-up leftovers) |
| [`kernel/oneplus6.config`](patches/kernel/oneplus6.config) | Terminus 16x32 console font for the on-screen boot log |
| [`build`](patches/oh/build), [`arkcompiler/ets_runtime`](patches/oh/arkcompiler/ets_runtime) | host tools vs GCC 13 headers (Ubuntu 24.04) |
| [`third_party/jsframework`](patches/oh/third_party/jsframework), [`third_party/libnl`](patches/oh/third_party/libnl) | Node 14 for one tool while the build uses Node 18; autoconf 2.72 |

Each patch file starts with its rationale. [`docs/bringup-notes.md`](docs/bringup-notes.md) has the full
bring-up record: every failure, how it showed and what fixed it.

## Debugging a boot

- The screen's console (`console=tty0`, large font) shows only emergencies (`loglevel=1`): a flood of kernel errors
  drawn there froze the phone (see `BOOT_CMDLINE_BASE` in `scripts/config.sh`). To watch a boot,
  `BOOT_CMDLINE_EXTRA=ignore_loglevel scripts/06-make-boot.sh` shows every message.
- A phone that hangs or panics waits in Qualcomm crash-dump mode (USB `05c6:900e`) with its RAM intact; the main
  branch's `scripts/crashdump.py` reads the kernel's console log from there and restarts the phone.
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
docs/bringup-notes.md           how it was brought up, failure by failure
```

## Credits and licenses

Built on [OpenHarmony](https://gitee.com/openharmony) (Apache-2.0), the OnePlus 6T community port at
[gitee.com/ohos_port](https://gitee.com/ohos_port), the Linux kernel (GPL-2.0, the kernel patches are under the
kernel's license) and AOSP `mkbootimg`. The patches here follow the licenses of the projects they apply to.
