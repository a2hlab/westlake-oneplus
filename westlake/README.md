# Android apps with Westlake on the OnePlus 6

[Westlake](https://github.com/a2hlab/westlake) runs Android apps on OpenHarmony: ART, the Android framework
and the app run in a process that the Westlake host app (an OH app) spawns, and the app draws into an OH window
over the host's window. These scripts run it on the OnePlus 6 with the OpenHarmony 6.1 build of this repo.

Verified 2026-11-18: from a fresh boot, `03` → `05` bring up Fossify Clock 1.6.0 (the unmodified APK) with the
time ticking, and taps on the touchscreen at the places its controls are shown work (the Stopwatch tab opens,
its start button starts it). Checked on the images of release `v6.1.0.31-r2`.

Verified 2026-11-18 on OpenHarmony 7.0 with SceneBoard (branch `oh-7.0`): `06-managed.sh` runs Fossify Clock as an OH
application ([below](#openharmony-70-with-sceneboard-managed-launch)). Its window sits between OH's bars and keeps
updating. Taps arrive through OH's own input. The add-timer dialog is drawn centred, OH's keyboard opens for its
label field and typing reaches it, and BACK hides the keyboard, then closes the dialog.

## What is different from Westlake's test board

The test board runs the same OpenHarmony version (6.1.0.31), so every Westlake binary links against this
build's libraries. Four things differ:

| | test board | OnePlus 6 | handled by |
|---|---|---|---|
| GPU driver | Mali, `libGLES_mali.z.so` | Adreno through Mesa freedreno; no such file | `01` builds an empty stand-in that depends on OH's `libEGL.so`, `libGLESv3.so`, `libbuffer_handle.z.so` |
| window manager | SceneBoard | the classic window manager (SceneBoard's app is not in OH's public source) | Westlake fixes (`02` builds that bridge): the activity's sub-window gets the host window as parent, no OH window animation, a full-screen window, and OH's status and navigation bars as the app's insets |
| touchscreen | `event2`, 1200x1920 | `event1` (Synaptics S3706B), 1080x2280 | `--touch-device` / `--touch-size` of the launch probe |
| toybox | has `sha256sum`, `chcon` | neither | `03` bind-mounts a `/system/bin` copy with an openssl `sha256sum` and a no-op `chcon` (SELinux is off) |

Without the window-manager fix the app runs and draws but is invisible: the classic window manager refuses the
parentless sub-window (`WM_ERROR_INVALID_PARENT`), and as a main window its surface keeps the start values of an
OH transition that never plays (alpha 0, scale 0).

## What you need

- the phone running OH from this repo (`scripts/11-boot-oh.sh`), hdc working;
- a Westlake source-closure directory (`WL_SC`) with Westlake's builds: the framework and boot image (built from the
  westlake checkout below: popups are placed by its Java), resources, core libraries, ART and native runtime,
  appspawn, a runtime-library override, the bionic shim, the WebView input, the signed host HAP and a prepared app
  input (Westlake's build chain makes them);
- a westlake checkout with the classic-window-manager fixes (full-screen window with OH's bars as insets, dialogs at
  their own size, popups placed where their taps go) and touchfwd's first-touch fix (`WL_WESTLAKE`,
  branch `oneplus-classic-wms`, [westlake#175](https://github.com/a2hlab/westlake/pull/175));
- a manifest checkout whose `tools/probe_source_app.py` has `--touch-device` (`WL_MANIFEST`, branch
  `oneplus-touch`, [manifest#71](https://github.com/a2hlab/manifest/pull/71)).

Put the paths and the build directory names in `westlake/local.sh` (git-ignored); `config.sh` lists the
variables. On WSL with the Windows `hdc.exe`, set `HDC_EXE` and `WL_HDC=westlake/tools/hdc-retry.sh`, which
repeats calls that a dead WSL interop socket dropped (the probes fail on a lost call). It follows
westlake-harness `device/hdc_wsl.sh` and adds the repeat: here a socket that had just passed that script's check
still failed the next call.

## Steps

| script | when | what |
|---|---|---|
| `01-phone-runtime.sh` | once per OH build | pulls the OH libraries Westlake links against, writes the firmware list with this phone's hashes, builds the GPU stand-in, makes `native-runtime-op6` |
| `02-bridge.sh` | once per Westlake change | builds `liboh_adapter_bridge.so` (for `WL_OH`) and the spawner `appspawn-x` into `override-op6` |
| `03-prep.sh` | after every boot | `sha256sum`/`chcon` on the phone, the kernel wake lock `no_suspend` if the image did not take it (suspend drops USB here), installs the host HAP |
| `04-framework.sh` | after every boot | stages the framework and checks that it initialises (~3 min) |
| `05-launch.sh APP` | per app (6.1) | launches the app over the host's window; prints the window lines and saves a screenshot |
| `06-managed.sh APP` | per app (7.0) | makes, signs and installs the app's own OH bundle, launches it through OH; saves a screenshot |
| `tap.sh X Y` | tests | a tap through the touchscreen's input node at screen pixel X,Y, as a finger would |

`/data` is a RAM disk on this build, so `03` and `04` are repeated after each boot; nothing is written to the
phone's partitions. `04` runs without the contract suite: its network contract needs a network connection,
which the phone does not have on its own (no SIM; Wi-Fi switches on and finds networks since release
`v6.1.0.31-r2`, joining one is not tested yet), and the launch needs only the preload to pass.

Keep the host app running between launches (`05` does): every host start gets a new window id, and the probe
reads the id from the host's `window-state.json`. `05` stops the apps of earlier launches the way westlake-harness
`device/config.sh` `kill_children` does (every process of the host's uid but the host, then appspawn-x): killing
appspawn-x alone leaves them running, and an earlier app's window stays above the new one.

## The app's window

On OH's classic window manager the activity's window is a sub-window of the host's. Before the fixes of
westlake#175 it was created in the area between the status bar and the navigation bar and then switched to full
screen; the window manager then reported it full screen, but its surface kept the smaller area (`[0, 108, 1080,
2064]`), so the full-screen frame was shown squeezed and touches near the top and bottom landed up to 108 px off.
Hiding OH's bars for the window only drew them empty: their windows stayed above the app and took the touches
meant for its bottom tabs. Now the window is full screen from the start, OH's bars stay, and they reach the app
as insets through the same code the SceneBoard path uses (`OhInsetsBridge.systemBars`, ADR-0008): the app lays
itself out between them, and a touch lands where it is shown, with no setting per screen. (OH draws its bar icons
white, so on a light app they do not show; the bars still work.)

Dialogs: every app window, a dialog too, is such a sub-window, and each draws into a content node of its own that
placement moves inside the display-sized OH window, as on SceneBoard. On the classic window manager that node is
a render-service node; as the divided-render node it was before, a bounds update reached only one of the two
copies RenderService kept, and Clock's add-timer dialog was stretched over the whole screen.

Popups (menus, dropdowns): a popup's window is laid out in its parent's frame, as Android does. The framework placed
it in the display frame instead, below the status bar once the window had OH's bars as insets, so it was drawn a
status bar lower than its views and taps: on Clock's overflow menu a tap on Settings opened About. A framework built
from the westlake branch places it where Android does.

## OpenHarmony 7.0 with SceneBoard: managed launch

On 7.0 the phone runs SceneBoard, the window manager OpenHarmony and HarmonyOS phones use (branch `oh-7.0` of this
repo). SceneBoard refuses a direct launch's window: a sub-window must come from the process that owns its parent
window, and the app runs in a process of its own. So on 7.0 each APK runs as an OH application, Westlake's managed
launch ([ADR-0008](https://github.com/a2hlab/westlake/blob/main/docs/adr/0008-one-oh-process-model-for-apks-and-haps.md)):

- the APK gets its own OH bundle, named after its package, made from the unsigned host build `WL_HOST_BUILD` and
  signed with OH's public development certificates (`bm install -r` keeps its uid and data);
- OH's application manager asks Westlake's spawner for the process (`appspawn-x` on the `CJAppSpawn` socket, as for a
  Cangjie app; the launch probe starts a router there), and the app attaches to OH as an OH app does;
- SceneBoard gives the app its main window, lifecycle and input, so no touch forwarder runs.

What it needs, besides the 6.1 setup above:

- `WL_OH=7.0`, and `WL_BRIDGE_HEADERS` naming a header build of the 7.0 tree (OH include directories, IDL-generated
  headers);
- a westlake checkout of branch `oneplus-oh70` (`WL_WESTLAKE`): the bridge built against 7.0
  (`native/bridge15-sources-oh70.json`), 7.0's session calls, and the spawner's admission without SELinux. The
  framework and boot image (`WL_FRAMEWORK`, `WL_BOOT`) are built from the same checkout;
- a manifest checkout with both the managed launch (`--managed`, `tools/make_managed_bundle.py`) and the touch options
  (`WL_MANIFEST`);
- `WL_HOST_BUILD`: the unsigned host build the host HAP is signed from.

Run `01` to `04` as on 6.1 (`02` builds the spawner too), unlock the phone, then `06-managed.sh APP`. Unlock a minute
or so after boot: an unlock while the system is still starting can block SceneBoard for 6 s, and OH then restarts it.

Three things had to change for 7.0, and what happens without them:

| | without it | fix |
|---|---|---|
| hmdfs on a RAM disk | the storage daemon cannot mount hmdfs on `/data` (tmpfs), user 100 is never unlocked, and SceneBoard refuses to start any app that is not a system app (`ERR_BLOCK_START_FIRST_BOOT_SCREEN_UNLOCK`) | `const.distributed_file_property.enabled=false` in the product's parameters (branch `oh-7.0`, vendor patch) |
| no SELinux | the spawner admits OH's application manager by uid and SELinux context; this kernel has no SELinux, so it refused every spawn | westlake `oneplus-oh70`: where there is no selinuxfs, the uid alone admits it |
| SceneBoard makes the window's node | 7.0 sends a node id at Connect, and SceneBoard creates the window's render node with it. The id of a node the app had made itself left two nodes under one id, and under partial rendering every frame was skipped: SceneBoard's blur stayed on screen | westlake `oneplus-oh70`: a fresh id; the app's content node hangs under a root node of its own, under SceneBoard's node. The root node also tells SceneBoard the first frame is there, so it removes the starting window |

