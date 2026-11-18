# Android apps with Westlake on the OnePlus 6

[Westlake](https://github.com/a2hlab/westlake) runs Android apps on OpenHarmony: ART, the Android framework
and the app run in a process that the Westlake host app (an OH app) spawns, and the app draws into an OH window
over the host's window. These scripts run it on the OnePlus 6 with the OpenHarmony 6.1 build of this repo.

Verified 2026-11-18: from a fresh boot, `03` → `05` bring up Fossify Clock 1.6.0 (the unmodified APK) with the
time ticking, and taps on the touchscreen at the places its controls are shown work (the Stopwatch tab opens,
its start button starts it). Checked on the release images (`v6.1.0.31-r1`) and on images with the Wi-Fi fixes.

## What is different from Westlake's test board

The test board runs the same OpenHarmony version (6.1.0.31), so every Westlake binary links against this
build's libraries. Four things differ:

| | test board | OnePlus 6 | handled by |
|---|---|---|---|
| GPU driver | Mali, `libGLES_mali.z.so` | Adreno through Mesa freedreno; no such file | `01` builds an empty stand-in that depends on OH's `libEGL.so`, `libGLESv3.so`, `libbuffer_handle.z.so` |
| window manager | SceneBoard | the classic window manager (SceneBoard's app is not in OH's public source) | Westlake fix: the activity's sub-window gets the host window as parent, and no OH window animation (`02` builds that bridge) |
| touchscreen | `event2`, 1200x1920 | `event1` (Synaptics S3706B), 1080x2280 | `--touch-device` / `--touch-size` of the launch probe |
| app frame on screen | full screen | squeezed between the status and navigation bars (y 108..2172) | touchfwd maps that area onto the frame (`WL_TOUCH_AREA`, `--touch-area`) |
| toybox | has `sha256sum`, `chcon` | neither | `03` bind-mounts a `/system/bin` copy with an openssl `sha256sum` and a no-op `chcon` (SELinux is off) |

Without the window-manager fix the app runs and draws but is invisible: the classic window manager refuses the
parentless sub-window (`WM_ERROR_INVALID_PARENT`), and as a main window its surface keeps the start values of an
OH transition that never plays (alpha 0, scale 0).

## What you need

- the phone running OH from this repo (`scripts/11-boot-oh.sh`), hdc working;
- a Westlake source-closure directory (`WL_SC`) with Westlake's builds: the framework, boot image, resources,
  core libraries, ART and native runtime, appspawn, a runtime-library override, the bionic shim, the WebView
  input, the signed host HAP and a prepared app input (Westlake's build chain makes them);
- a westlake checkout with the classic-window-manager fix and touchfwd's `WL_TOUCH_AREA` (`WL_WESTLAKE`,
  branch `oneplus-classic-wms`, [westlake#175](https://github.com/a2hlab/westlake/pull/175));
- a manifest checkout whose `tools/probe_source_app.py` has `--touch-device` and `--touch-area` (`WL_MANIFEST`,
  branch `oneplus-touch`, [manifest#71](https://github.com/a2hlab/manifest/pull/71)).

Put the paths and the build directory names in `westlake/local.sh` (git-ignored); `config.sh` lists the
variables. On WSL with the Windows `hdc.exe`, set `HDC_EXE` and `WL_HDC=westlake/tools/hdc-retry.sh`, which
repeats calls that a dead WSL interop socket dropped (the probes fail on a lost call).

## Steps

| script | when | what |
|---|---|---|
| `01-phone-runtime.sh` | once per OH build | pulls the OH libraries Westlake links against, writes the firmware list with this phone's hashes, builds the GPU stand-in, makes `native-runtime-op6` |
| `02-bridge.sh` | once per Westlake change | builds `liboh_adapter_bridge.so` with the classic-window-manager fix into `override-op6` |
| `03-prep.sh` | after every boot | `sha256sum`/`chcon` on the phone, installs the host HAP |
| `04-framework.sh` | after every boot | stages the framework and checks that it initialises (~3 min) |
| `05-launch.sh APP` | per app | launches the app; prints the window lines and saves a screenshot |
| `tap.sh X Y` | tests | a tap through the touchscreen's input node at screen pixel X,Y, as a finger would |

`/data` is a RAM disk on this build, so `03` and `04` are repeated after each boot; nothing is written to the
phone's partitions. `04` runs without the contract suite: its network contract needs a network connection,
which the phone does not have on its own (no SIM; Wi-Fi switches on and finds networks with images built from
this repository since 2026-11-18, joining one is not tested yet), and the launch needs only the preload to pass.

Keep the host app running between launches (`05` does): every host start gets a new window id, and the probe
reads the id from the host's `window-state.json`. `05` stops the apps of earlier launches: killing appspawn-x
leaves them running, and an earlier app's window stays above the new one.

## Touch positions

OH's classic window manager shows the app's full-screen frame (1080x2280) squeezed into the area between the
status bar and the navigation bar (`[0, 108, 1080, 2064]` on screen), while the app lays itself out for the
whole screen. touchfwd maps that area of the touchscreen onto the frame (`WL_TOUCH_AREA` in `config.sh`), so a
finger lands where it touches. Without it, touches near the top and bottom edges land up to 108 px off, and
the Clock's tabs do not respond. The area is a fixed setting: rotation, another bar size or a split screen
needs its own. The fix that makes it automatic belongs in Westlake: lay the app out in the area OH shows it
in, or give the app the bars as insets.
