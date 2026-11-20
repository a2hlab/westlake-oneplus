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
| `03-prep.sh` | after every boot | `sha256sum`/`chcon` on the phone, the kernel wake lock `no_suspend` if the image did not take it (suspend drops USB here), no automatic restart of the audio and compute DSPs, installs the host HAP |
| `04-framework.sh` | after every boot | stages the framework and checks that it initialises (~3 min) |
| `05-launch.sh APP` | per app (6.1) | launches the app over the host's window; prints the window lines and saves a screenshot |
| `06-managed.sh APP` | per app (7.0) | makes, signs and installs the app's own OH bundle, launches it through OH; saves a screenshot |
| `07-round.sh TAG [FIRST [LAST]]` | corpus rounds (7.0) | the apps of a corpus, one after another as `06` launches one, with the evidence westlake-harness scores; see below |
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

Six things had to change for 7.0, and what happens without them:

| | without it | fix |
|---|---|---|
| hmdfs on a RAM disk | the storage daemon cannot mount hmdfs on `/data` (tmpfs), user 100 is never unlocked, and SceneBoard refuses to start any app that is not a system app (`ERR_BLOCK_START_FIRST_BOOT_SCREEN_UNLOCK`) | `const.distributed_file_property.enabled=false` in the product's parameters (branch `oh-7.0`, vendor patch) |
| no SELinux | the spawner admits OH's application manager by uid and SELinux context; this kernel has no SELinux, so it refused every spawn | westlake `oneplus-oh70`: where there is no selinuxfs, the uid alone admits it |
| SceneBoard makes the window's node | 7.0 sends a node id at Connect, and SceneBoard creates the window's render node with it. The id of a node the app had made itself left two nodes under one id, and under partial rendering every frame was skipped: SceneBoard's blur stayed on screen | westlake `oneplus-oh70`: a fresh id; the app's content node hangs under a root node of its own, under SceneBoard's node. The root node also tells SceneBoard the first frame is there, so it removes the starting window |
| OH's launch timeouts | OH ends an ability that is not attached within its load timeout (about 10 s from the process start) or does not report FOREGROUND within its foreground timeout (about 5 s); an Android app binds and draws more slowly than an OH app starts, and the bridge answered OH's calls only as the app got to them: Instagram's 9.5 s bind (SceneBoard: `handleLoadTimeout`) and Spotify's first frame 5 s after OH's request ended them before they drew | westlake `oneplus-oh70`: the bind and the activity launch run on threads of their own, so the ability is attached at once; ApplicationForegrounded and FOREGROUND are sent by the bridge when the app's main thread has not sent them in time (300 ms, 3.5 s) |
| `finishAffinity()` | Westlake answered it without finishing anything; WhatsApp's first activity finishes that way after starting its EULA, kept the OH ability, and the EULA's window waited for a main window that never came | westlake `oneplus-oh70`: it finishes the activities as Android's task manager does, so the ability passes to the next activity |
| the runtime library | the override build's `liboh_android_runtime.so` predates westlake's dialog fixes: a window smaller than the screen kept buffers of another size, and on this phone's Adreno the app's GPU wrote past them (IOMMU faults, GPU hang recovery; DramaWave in every run) | `02-bridge.sh` builds the library from the same checkout as the bridge when `WL_GUI_HEADERS` names the GUI AIDL header build (westlake `tools/generate_gui_aidl.py`) |

## Corpus rounds (7.0)

`07-round.sh` runs a corpus round on the phone (the Hong Kong top-1000 corpus of westlake-harness, or any directory
with its layout): every app is launched as `06-managed.sh` launches one, and its evidence is taken the way
westlake-harness `device/run_apps.sh` takes it on Westlake's test board (the app's log after a thread dump, a
screenshot, its hilog, process map, crash dump and spawner log), so that the harness's lifecycle scorer reads both
boards' rounds alike. Each app is staged with the harness's `device/prep_apps.py`, waits at most `WAIT` (45) seconds
and leaves once it is on screen (two screenshots in a row that are not SceneBoard's own screens) or gone, and is then
stopped and its bundle uninstalled. `logs/TAG/results.tsv` has a line per app; running the round again resumes it.

What it needs besides `06`'s settings (`local.sh`): `WL_HARNESS` (a westlake-harness checkout), `WL_CORPUS` (the
corpus: `apps.csv`, `sources.csv`, `dl/`, `map120/<package>/gap-map.json`) and `WL_CORPUS_LOCK` (the lock file with
its pins), `WL_GUESTS` (the microG guest build every app gets, as the harness's rounds give it) and `WL_ROUND`, a
directory for the round that `07-round.sh --setup` makes: a view of the corpus, a copy of `WL_MANIFEST` with the
corpus pins, the staged apps, the logs.

The phone's `/data` is a RAM disk, so a round keeps one app at a time and shares what it can: the framework and the
files every app gets (the WebView, runtime libraries and guests, sent once into the launcher's input cache) are
hard-linked into each app's bundle rather than copied, and the bundle's uninstall frees the rest. Before each app
`/data` must have `MIN_FREE_MB` (1400) free.

Scoring: `tools/round_score.py logs/TAG [--before <a D600 round's logs>] [--json scores.json]` is the harness's
`westlake_gap.lifecycle` with SceneBoard's screens as the "host" screens (`refs/`: the desktop, and the plain white
starting window of an app that has not drawn; `tools/round_screen.py --make-ref` makes one from a screenshot), and
with the managed launch's bind line as the "bound" marker. `tools/round_compare.py` lists the apps whose rung
differs between the phone and the D600.

Rounds pass `WESTLAKE_SECURE_LAYER=0`, so that a window that sets `FLAG_SECURE` stays an ordinary OH layer and the
screenshot shows it; as an OH security layer it is captured black (Spotify's login screen). The app still sees its
flag set. `SECURE_LAYER=1` keeps the security layers.

Rounds also give apps the locale `en-US` (`LOCALE`; `WESTLAKE_LOCALE` in the app's environment), as on Westlake's
test board, whose language is English: this image's default language is Chinese, and an app that sees `zh_CN` may
take another path (a region check, another first screen). `LOCALE=` keeps the phone's own.

### Unattended rounds

The phone can hang under load (it waits in Qualcomm crash-dump mode until it is restarted), so long rounds run
under `tools/supervise-round.sh TAG [FIRST [LAST]]` (start it with `setsid nohup bash ...`). Every shell call of
`07-round.sh` on the phone has a time limit (`DEV_TIMEOUT`, 300 s), so a hang stops the round (exit 4) instead of
leaving it waiting; the supervisor then has the phone captured and restarted by `scripts/recover-phone.sh` (the
kernel's own log, tasks and stacks, TrustZone's diagnostics: `scripts/crashdump.py`), waits for a phone that
rebooted by itself, runs `03` and `04` again and resumes the round. An app the phone went away during twice gets the
result `phone-hung` and is skipped. Settings: `recover-phone.sh`'s (its header), and `WL_ENV`, a file of settings
sourced first (e.g. those of the 7.0 setup). The phone should start OH by itself after a reset (branch `oh-7.0`:
`13-flash-boot.sh`, and `14-data-partition.sh` so that `/data` and the Wi-Fi login stay); otherwise
`recover-phone.sh` RAM-boots it, but only with `SERIAL` set.

Beside it, `tools/kmsg-watch.sh TAG` keeps the phone's kernel log on the host every 5 s (the last lines before a hang
are there even when no RAM capture can be made) and reboots the phone when the audio or compute DSP crashed
(`03` turns their automatic restart off: this kernel's restart is not safe). `tools/finish-round.sh TAG [BASE]`
waits for the first pass, launches again the apps that did not launch (not the `phone-hung` ones), and reports;
`tools/round-report.sh TAG [BASE]` gives the numbers of a round so far (scores, rungs, the apps whose rung differs
from `BASE`, a `round_score.py --json` output or a D600 round's scores).

`tools/hdc-retry.sh` can log the time of every hdc call (start, end, exit code, arguments) while the file
`HDC_TIMING_FLAG` exists (`HDC_TIMING_LOG`; both default to `$XDG_RUNTIME_DIR`), to profile a round.
`tools/hdc-profile.py TIMING_LOG round-TAG.log` then says where each app's turn went: its hdc calls by kind (shell,
file send, file recv), the time between them (host-side work and waits), and the longest calls and gaps.


### Two phones

A round can be shared by two phones running the same OH build, each taking a part of the apps (2026-11-20: 127
apps left of the Hong Kong round, 64 and 63, about half the time). Each phone needs its own hdc serial first: every
phone on these images gets the same one (branch `oh-7.0`, `docs/second-phone.md`).

Each phone gets a settings file for `WL_ENV`. For the second one, besides the 7.0 settings the first one uses:

```sh
HDC_TARGET=<its hdc serial>
WL_OUT=<its own output directory>    # 04-framework.sh writes the device report the round reads into it
WL_ROUND=<its own round directory>   # its staged apps, logs and installed-bundle record (.installed)
RECOVER=none                         # see below
```

1. `01-phone-runtime.sh` and `02-bridge.sh` are per OH build, so with the same build a copy of the first phone's
   `WL_OUT` serves (without its test launches, `managed-*` and `launch-*`). Then, with the second phone's settings:
   `03-prep.sh`, `04-framework.sh`, and `07-round.sh --setup` for its round directory.
2. `07-round.sh` makes its list of apps when it starts and skips only the apps that already have a line in its own
   `results.tsv`, so the phones get separate lists: what is left of `apps.csv` (not marked missing in
   `sources.csv`, no line in the first round's `results.tsv`), in order, the first half in one `LIST` file and the
   rest in another. A runner that is already going keeps its list until it starts again: stop its supervisor's
   process group and start it with its `LIST` (the app it was running is launched again).
3. Start each phone's supervisor with its settings and its list:
   `WL_ENV=<its settings> LIST=<its list> setsid nohup tools/supervise-round.sh TAG >/dev/null 2>&1 &`.
   A phone in crash-dump mode cannot be told from the other one (both are the same Qualcomm device), so only the
   first phone's supervisor resets phones; the second one's (`RECOVER=none`) waits for its phone to come back and
   then runs `03` and `04` again. A `kmsg-watch.sh` per phone (`WL_ENV`) keeps each phone's kernel log in its own
   round directory.
4. Finish from the first phone's settings: `MERGE_FROM=<the second round directory> tools/finish-round.sh TAG BASE`
   (without `LIST`). Every supervisor of round TAG counts, so it waits for both phones; then `merge-round.sh`
   appends the second phone's `results.tsv` lines and copies its per-app logs for the apps the first round has no
   line for, a completion pass on the first phone launches whatever neither phone reached, and the retry pass and
   the report run on the merged round as for one phone.
