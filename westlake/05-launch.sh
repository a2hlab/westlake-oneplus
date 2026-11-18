#!/bin/bash
# Launch an Android app with Westlake: 05-launch.sh APP (a key of the manifest's app-inputs.lock.json, with
# WL_APP_INPUT_<APP> naming its prepared input). Run after 04-framework.sh. The app opens over the host's window;
# touches on the screen reach it through touchfwd (the Synaptics touchscreen, event1).
# Afterwards: $WL_OUT/launch-APP/ has the probe's report, launch-APP.jpeg is a screenshot.
set -euo pipefail
. "$(dirname "$0")/config.sh"
app=${1:?usage: $0 APP}
var=WL_APP_INPUT_$app; wl_need WL_SC WL_WESTLAKE WL_MANIFEST WL_OVERRIDE WL_SHIM WL_WEBVIEW_INPUT "$var"
[ -f "$WL_OUT/framework/device-report.json" ] || die "run 04-framework.sh first"
[ -d "$WL_OUT/override-op6" ] || die "run 02-bridge.sh first"
grep -q -- '--touch-area' "$WL_MANIFEST/tools/probe_source_app.py" \
  || die "$WL_MANIFEST/tools/probe_source_app.py has no --touch-area (see westlake/README.md)"
grep -q WL_TOUCH_AREA "$WL_WESTLAKE/native/touchfwd.c" \
  || die "$WL_WESTLAKE/native/touchfwd.c has no WL_TOUCH_AREA (see westlake/README.md)"
# Killing appspawn-x does not stop the apps it started (they move to init), and an earlier app's window stays above
# the next one, which then gets the taps unseen. Each launch report names its app process and uid.
old=$(for r in "$WL_OUT"/launch-*/device-report.json; do [ -f "$r" ] || continue
  python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); print("%s:%s" % (d["child"], d["uid"]))' "$r" || true
done | tr '\n' ' ')
out=$WL_OUT/launch-$app; rm -rf "$out"
rl=(); for l in $WL_RUNTIME_LIBS; do rl+=(--runtime-library "$l"); done

step "stop an earlier launch"
# Keep the host running: a host start gets a new window, and the probe reads the host's window id. An earlier app
# is stopped only while that pid still runs under its report's uid, and never the host (it has the same uid).
wl_hdc shell 'h=$(pidof '"$WL_HOST"'); for e in '"$old"'; do p=${e%:*}; u=${e#*:};
    [ "$p" != "$h" ] && [ "$(stat -c %u /proc/$p 2>/dev/null)" = "$u" ] && kill $p; done;
  for p in $(pidof appspawn-x) $(pidof touchfwd); do kill $p; done; sleep 1;
  rm -rf /data/local/tmp/a2hlab-app-* /data/app/el2/100/base/'"$WL_HOST"'/files/a2hlab-source-*; exit 0' >/dev/null

# The probe compiles its native helpers from --westlake-source: the namespace and spawn helpers as the
# source-closure workspace has them, the touch forwarder from $WL_WESTLAKE (WL_TOUCH_AREA).
helpers=$WL_OUT/helpers; rm -rf "$helpers"; mkdir -p "$helpers/native"
cp "$WL_SC/workspace/westlake/native/"{source_app_namespace.c,host_spawn.c} "$WL_WESTLAKE/native/touchfwd.c" "$helpers/native/"

step "launch $app"
cd "$WL_SC"
python3 "$WL_MANIFEST/tools/probe_source_app.py" --workspace "$WL_SC/verify" --westlake-source "$helpers" \
  --framework-report "$WL_OUT/framework/device-report.json" --app-input "$(wl_build "${!var}")" --app "$app" \
  --webview-input "$(wl_build "$WL_WEBVIEW_INPUT")" --bionic-shim-build "$(wl_build "$WL_SHIM")" \
  --runtime-library-build "$WL_OUT/override-op6" "${rl[@]}" --android-native-net-app-libraries \
  --touch-mode tap --touch-device "$WL_TOUCH_DEVICE" --touch-size "$WL_TOUCH_SIZE" --touch-area "$WL_TOUCH_AREA" \
  --hdc "$WL_HDC" --serial "$HDC_TARGET" --out "$out" > "$out.log" 2>&1 || { tail -20 "$out.log"; die "launch failed"; }
grep -o 'SOURCE_APP_SPAWNED.*' "$out.log" | head -1

step "window"
sleep 15
child=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["child"])' "$out/device-report.json")
runtime=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["runtime"])' "$out/device-report.json")
wl_hdc shell "grep -E 'legacy SUB_WINDOW parent|CreateWindow ret|AddWindow ret' $runtime/private-tmp/adapter_child_$child.stderr" | tr -d '\r'
wl_hdc shell "snapshot_display -f /data/local/tmp/wl-launch.jpeg >/dev/null 2>&1; exit 0" >/dev/null
(cd "$WL_OUT" && wl_hdc file recv /data/local/tmp/wl-launch.jpeg "$(wl_tool_path "$WL_OUT")/launch-$app.jpeg" >/dev/null)
echo "screenshot: $WL_OUT/launch-$app.jpeg"
