#!/bin/bash
# Settings for running Android apps with Westlake on the OnePlus 6 (OpenHarmony 6.1 from this repo).
# Machine paths and the names of your Westlake builds go in westlake/local.sh (git-ignored); see README.md.
WL_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$WL_DIR/../scripts/config.sh"
[ -f "$WL_DIR/local.sh" ] && . "$WL_DIR/local.sh"

# --- Westlake checkouts and builds ---
: "${WL_SC:=}"            # Westlake source-closure directory (has workspace/ and verify/out/)
: "${WL_WESTLAKE:=}"      # westlake checkout with the classic-window-manager fix (for the bridge build)
: "${WL_MANIFEST:=}"      # manifest checkout whose probe_source_app.py has --touch-device/--touch-size
: "${WL_OUT:=$WORK_DIR/westlake}"   # generated here: phone libraries, OnePlus runtime copy, bridge, reports
# Westlake build directories (under $WL_SC/verify/out unless absolute), set in local.sh:
#   WL_APPSPAWN WL_CORE_RUNTIME WL_NATIVE_RUNTIME WL_CORE_JAVA WL_JAVA_EXT WL_FRAMEWORK WL_BOOT WL_RES WL_DATA
#   WL_USES_LIBS (space-separated), WL_OVERRIDE (runtime-library override the bridge is added to),
#   WL_SHIM (bionic shim), WL_WEBVIEW_INPUT, WL_HOST_HAP (signed host HAP), WL_APP_INPUT_<app> (prepared app)
: "${WL_RUNTIME_LIBS:=libandroid_native_network_compat.so libart.so libcamera2ndk.so libmediandk.so liboh_adapter_bridge.so liboh_android_runtime.so libvulkan.so libwl_missing_natives.so}"
: "${WL_HOST:=org.westlake.imehost}"

# --- the phone ---
: "${WL_HDC:=$HDC}"                     # hdc the Westlake probes run (on WSL: westlake/tools/hdc-retry.sh)
WL_TOUCH_DEVICE=/dev/input/event1       # Synaptics S3706B (event2 is the volume keys)
WL_TOUCH_SIZE=1080x2280                 # its raw range 0..1079 x 0..2279 covers the whole screen

wl_build() {  # wl_build NAME -> directory of a Westlake build
  local n=$1; [ -n "$n" ] || die "a Westlake build is not set (westlake/local.sh)"
  case "$n" in /*) printf '%s\n' "$n" ;; *) printf '%s\n' "$WL_SC/verify/out/$n" ;; esac
}
wl_need() {   # wl_need VAR... : every variable must be set
  local v; for v in "$@"; do [ -n "${!v:-}" ] || die "$v is not set (westlake/local.sh, see westlake/README.md)"; done
}
wl_hdc() { "$WL_HDC" -t "$HDC_TARGET" "$@" </dev/null; }
wl_tool_path() {  # a local path as hdc can open it (Windows form for hdc.exe, also behind tools/hdc-retry.sh)
  if is_win_tool "$WL_HDC" || [ -n "${HDC_EXE:-}" ]; then wslpath -w "$(readlink -f "$1")"; else readlink -f "$1"; fi
}
