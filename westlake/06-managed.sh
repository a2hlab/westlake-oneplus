#!/bin/bash
# Launch an Android app as an OH application (westlake ADR-0008, managed launch): 06-managed.sh APP (a key of the
# manifest's app-inputs.lock.json, with WL_APP_INPUT_<APP> naming its prepared input). Run after 04-framework.sh,
# on OpenHarmony 7.0 with SceneBoard (WL_OH=7.0), where SceneBoard refuses a direct launch's window: a sub-window
# must come from its parent window's process.
#
# The APK gets its own OH bundle, named after its package, made from the unsigned host build $WL_HOST_BUILD and
# signed with OH's public development certificates. OH's application manager asks Westlake's spawner for the
# app's process (appspawn-x on the CJAppSpawn socket, as a Cangjie app's), and SceneBoard gives the app its own
# main window, lifecycle and input: no touch forwarder runs.
# Afterwards: $WL_OUT/managed-APP/ has the bundle, the probe's report (launch/) and managed-APP.jpeg.
# WL_PROBE_ARGS adds launch-probe options (for example --runtime-env NAME=VALUE for the app's environment).
# APP_PROCESSES=0: every component in the launched process (07-round.sh's APP_PROCESSES).
set -euo pipefail
. "$(dirname "$0")/config.sh"
app=${1:?usage: $0 APP}
var=WL_APP_INPUT_$app; wl_need WL_SC WL_WESTLAKE WL_MANIFEST WL_SHIM WL_WEBVIEW_INPUT WL_HOST_BUILD "$var"
[ -f "$WL_OUT/framework/device-report.json" ] || die "run 04-framework.sh first"
[ -x "$WL_OUT/override-op6/lib/appspawn-x" ] || die "run 02-bridge.sh first"
grep -q -- "'--managed'" "$WL_MANIFEST/tools/probe_source_app.py" && [ -f "$WL_MANIFEST/tools/make_managed_bundle.py" ] \
  || die "$WL_MANIFEST has no managed launch (see westlake/README.md)"
input=$(wl_build "${!var}")
read -r pkg activity < <(python3 -I -c 'import json, sys
a = json.load(open(sys.argv[1]))["application"]; print(a["package"], a["launch_activity"])' "$input/app-input.json")
out=$WL_OUT/managed-$app; rm -rf "$out"; mkdir -p "$out"
rl=(--runtime-library appspawn-x); for l in $WL_RUNTIME_LIBS; do rl+=(--runtime-library "$l"); done

# The launcher activity's android:screenOrientation, for the ability (07-round.sh's orientation_of): the input's
# base APK is its APK that is not one of its splits.
orient=""
if [ "${ORIENTATION:-1}" != 0 ] && grep -q -- "'--orientation'" "$WL_MANIFEST/tools/make_managed_bundle.py"; then
  base=$(python3 -I -c 'import json, sys, pathlib
d = pathlib.Path(sys.argv[1]); splits = {s["name"] for s in json.load(open(d / "app-input.json"))["application"].get("splits", [])}
print(next((str(p) for p in sorted(d.glob("*.apk")) if p.name not in splits), ""))' "$input")
  [ -n "$base" ] && orient=$(python3 -P "$WL_DIR/tools/launcher_orientation.py" --download "$base" --activity "$activity" 2>/dev/null) || orient=""   # set -e: an unreadable manifest only leaves it out
fi
step "OH bundle $pkg (ability $activity${orient:+, screenOrientation $orient})"
python3 "$WL_MANIFEST/tools/make_managed_bundle.py" --host-build "$(wl_build "$WL_HOST_BUILD")" --package "$pkg" \
  --activity "$activity" ${orient:+--orientation "$orient"} --out "$out/bundle" | tail -1
python3 "$WL_MANIFEST/tools/sign_development_host.py" --workspace "$WL_SC/verify" --host-build "$out/bundle" \
  --managed --out "$out/signed" | tail -1
wl_hdc file send "$(wl_tool_path "$out/signed/source-host.hap")" /data/local/tmp/wl-managed.hap >/dev/null
# -r keeps the bundle's uid, and with it the app's data, across launches.
wl_hdc shell "bm install -r -p /data/local/tmp/wl-managed.hap" | tr -d '\r' | tail -1
wl_hdc shell "bm dump -n $pkg" | grep -q '"bundleName"' || die "the bundle did not install"

step "stop an earlier launch"
# OH ends the app (its process, windows and ability record). A direct launch of the same app (05-launch.sh) runs
# under the package's name too. Then the spawners, as 05-launch.sh does, the router included, so that the next
# one runs this build's appspawn-x.
wl_hdc shell "aa force-stop $pkg >/dev/null; for p in \$(pidof $pkg); do kill -9 \$p; done;
  for p in \$(pidof appspawn-x) \$(pidof touchfwd); do kill \$p; done; sleep 1;
  rm -rf /data/local/tmp/a2hlab-app-* /data/app/el2/100/base/$pkg/files/a2hlab-source-*; exit 0" >/dev/null

helpers=$out/helpers; mkdir -p "$helpers/native"
cp "$WL_SC/workspace/westlake/native/"{source_app_namespace.c,host_spawn.c} "$WL_WESTLAKE/native/touchfwd.c" "$helpers/native/"

step "launch $app through OH"
cd "$WL_SC"
python3 "$WL_MANIFEST/tools/probe_source_app.py" --workspace "$WL_SC/verify" --westlake-source "$helpers" \
  --framework-report "$WL_OUT/framework/device-report.json" --app-input "$input" --app "$app" \
  --webview-input "$(wl_build "$WL_WEBVIEW_INPUT")" --bionic-shim-build "$(wl_build "$WL_SHIM")" \
  --runtime-library-build "$WL_OUT/override-op6" "${rl[@]}" --android-native-net-app-libraries \
  --host "$pkg" --managed --touch-mode off ${WL_PROBE_ARGS:-} \
  $([ "${APP_PROCESSES:-1}" = 1 ] && echo --runtime-env WESTLAKE_APP_PROCESSES=1) \
  --hdc "$WL_HDC" --serial "$HDC_TARGET" --out "$out/launch" > "$out/launch.log" 2>&1 \
  || { tail -20 "$out/launch.log"; die "launch failed"; }
grep -o 'SOURCE_APP_SPAWNED.*' "$out/launch.log" | head -1 | cut -c1-120

step "window"
sleep 15
child=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["child"])' "$out/launch/device-report.json")
runtime=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["runtime"])' "$out/launch/device-report.json")
wl_hdc shell "grep -E 'WL-MANAGED|CreateAndConnectSpecificSession' $runtime/private-tmp/adapter_child_$child.stderr | head -12" \
  | tr -d '\r' | cut -c1-160
wl_hdc shell "snapshot_display -f /data/local/tmp/wl-managed.jpeg >/dev/null 2>&1; exit 0" >/dev/null
(cd "$WL_OUT" && wl_hdc file recv /data/local/tmp/wl-managed.jpeg "$(wl_tool_path "$out")/managed-$app.jpeg" >/dev/null)
echo "screenshot: $out/managed-$app.jpeg"
