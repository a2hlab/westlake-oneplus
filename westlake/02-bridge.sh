#!/bin/bash
# Build Westlake's window/ability bridge (liboh_adapter_bridge.so) from $WL_WESTLAKE for the OpenHarmony release on the
# phone (WL_OH). On 6.1 (classic window manager) $WL_WESTLAKE must carry the classic-window-manager fix: the bridge
# creates windows through the legacy IWindowManager, where the activity's sub-window needs the host window as parent
# and no OH window animation, OH's bars reach the app as insets, and each window (a dialog too) draws into a content
# node that is a render-service node. On 7.0 (SceneBoard) it is built against 7.0's headers and libraries (westlake
# branch oneplus-oh70). Writes $WL_OUT/override-op6: a copy of $WL_OVERRIDE with this bridge and with the spawner
# (appspawn-x) built from the same checkout, which a managed launch (06-managed.sh) runs.
set -euo pipefail
. "$(dirname "$0")/config.sh"
wl_need WL_SC WL_WESTLAKE WL_OVERRIDE WL_NATIVE_RUNTIME
grep -q 'legacy SUB_WINDOW parent' "$WL_WESTLAKE/framework/window/jni/oh_window_manager_client.cpp" \
  && grep -q 'wl_legacyHostSub' "$WL_WESTLAKE/framework/window/jni/oh_window_manager_client.cpp" \
  && grep -qF 'isWindow=*/sceneProxy_ == nullptr' "$WL_WESTLAKE/framework/window/jni/oh_window_manager_client.cpp" \
  || die "$WL_WESTLAKE lacks the classic-window-manager fixes (see westlake/README.md)"
ws=$WL_SC/workspace; b=$WL_OUT/bridge; rm -rf "$b"; mkdir -p "$b"
cd "$WL_WESTLAKE"

wl_need WL_BRIDGE_HEADERS
step "compile the bridge sources ($WL_BRIDGE_INVENTORY, OpenHarmony $WL_OH)"
python3 tools/compile_native_inventory.py --workspace "$ws" --inventory "$WL_BRIDGE_INVENTORY" \
  --westlake-source "$WL_WESTLAKE" --header-build "$WL_BRIDGE_HEADERS" --out "$b/objects" | tail -1
printf '{"liboh_adapter_bridge.so": {"build": "%s"}}\n' "$b/objects" > "$b/map.json"

step "link"
python3 tools/build_native_imports.py --workspace "$ws" --firmware-abi "$WL_FIRMWARE_ABI" \
  --object-map "$b/map.json" --out "$b/imports" | tail -1
python3 tools/link_native_platform.py --workspace "$ws" --object-map "$b/map.json" --imports "$b/imports" \
  --core-runtime "$(wl_build "$WL_NATIVE_RUNTIME")" --out "$b/link" | tail -1
lib=$b/link/liboh_adapter_bridge.so; [ -s "$lib" ] || die "no $lib"

step "spawner (appspawn-x)"
# The phone's kernel has no SELinux, so the spawner must admit OH's application manager by its uid alone.
grep -q 'no SELinux on this system' "$WL_WESTLAKE/framework/appspawn-x/src/spawn_server.cpp" \
  || die "$WL_WESTLAKE's appspawn-x needs the SELinux-free admission (see westlake/README.md)"
a=$b/spawner; mkdir -p "$a"; echo '{}' > "$a/empty.json"
python3 tools/compile_native_inventory.py --workspace "$ws" --inventory native/appspawn-sources.json \
  --westlake-source "$WL_WESTLAKE" --out "$a/objects" | tail -1
python3 tools/build_native_imports.py --workspace "$ws" --firmware-abi "$WL_FIRMWARE_ABI" \
  --object-map "$a/empty.json" --out "$a/imports" | tail -1
python3 tools/link_appspawn.py --workspace "$ws" --objects "$a/objects" --runtime "$(wl_build "$WL_NATIVE_RUNTIME")" \
  --core-runtime "$(wl_build "$WL_NATIVE_RUNTIME")" --imports "$a/imports" --out "$a/link" | tail -1 | cut -c1-100
[ -s "$a/link/appspawn-x" ] || die "no $a/link/appspawn-x"

# The runtime library (liboh_android_runtime.so) from the same checkout: the override build's copy predates the
# dialog fixes (westlake bbf83eb: a window's buffer queue follows the window's size), and on this phone's Adreno a
# window drawn into buffers of another size wrote past them (GPU faults; DramaWave had them, then none). It needs
# the GUI AIDL header build (tools/generate_gui_aidl.py), WL_GUI_HEADERS.
runtime_lib=""
if [ -n "${WL_GUI_HEADERS:-}" ]; then
  step "runtime library (liboh_android_runtime.so)"
  r2=$b/runtime; mkdir -p "$r2"
  python3 tools/compile_native_inventory.py --workspace "$ws" --inventory native/android-runtime15-sources.json \
    --westlake-source "$WL_WESTLAKE" --header-build "$WL_GUI_HEADERS" --out "$r2/objects" | tail -1
  printf '{"liboh_android_runtime.so": {"build": "%s", "additional_dependencies": ["libandroid.so", "libwestlake_libcore_linux.so"]}}\n' \
    "$r2/objects" > "$r2/map.json"
  python3 tools/build_native_imports.py --workspace "$ws" --firmware-abi "$WL_FIRMWARE_ABI" \
    --object-map "$r2/map.json" --out "$r2/imports" | tail -1
  python3 tools/link_native_platform.py --workspace "$ws" --object-map "$r2/map.json" --imports "$r2/imports" \
    --core-runtime "$(wl_build "$WL_NATIVE_RUNTIME")" --out "$r2/link" | tail -1
  runtime_lib=$r2/link/liboh_android_runtime.so; [ -s "$runtime_lib" ] || die "no $runtime_lib"
fi
step "override -> $WL_OUT/override-op6"
o=$WL_OUT/override-op6; rm -rf "$o"; cp -a "$(wl_build "$WL_OVERRIDE")" "$o"; cp "$lib" "$a/link/appspawn-x" $runtime_lib "$o/lib/"
python3 -I - "$o" "$(git -C "$WL_WESTLAKE" rev-parse --short HEAD)" "${runtime_lib:+liboh_android_runtime.so}" <<'EOF'
import hashlib, json, os, sys
o, rev = sys.argv[1:3]; p = os.path.join(o, 'artifacts.json'); d = json.load(open(p))
for name in ['liboh_adapter_bridge.so', 'appspawn-x'] + [n for n in sys.argv[3:] if n]:
    h = hashlib.sha256(open(os.path.join(o, 'lib', name), 'rb').read()).hexdigest()
    d['artifacts'][name]['sha256'] = h
    d['description'] = d.get('description', '') + '; OnePlus 6: ' + name + ' from westlake ' + rev
    d.setdefault('notes', []).append('OnePlus 6 copy: ' + name + ' ' + h[:8] + ' from westlake ' + rev)
    print(' ', name, h[:16])
json.dump(d, open(p, 'w'), indent=2)
EOF

if [ "$WL_OH" = 7.0 ]; then
  # The framework check (04) preloads the native runtime's own liboh_adapter_bridge.so, built against 6.1. On 7.0 six of
  # its imports do not resolve (OH changed those interfaces), so the runtime copy gets the bridge just built, the one
  # the app loads from the override. On 6.1 the runtime's own bridge resolves, and is kept.
  step "native runtime copy: the same bridge"
  r=$WL_OUT/native-runtime-op6; [ -d "$r" ] || die "$r missing: run 01-phone-runtime.sh first"
  cp "$lib" "$r/liboh_adapter_bridge.so"
  python3 -I - "$r" <<'EOF'
import hashlib, json, os, sys
r = sys.argv[1]; p = os.path.join(r, 'artifacts.json'); d = json.load(open(p))
b = open(os.path.join(r, 'liboh_adapter_bridge.so'), 'rb').read()
d['artifacts']['liboh_adapter_bridge.so'] = {'bytes': len(b), 'sha256': hashlib.sha256(b).hexdigest()}
d['scope'] += '; OpenHarmony 7.0: liboh_adapter_bridge.so is the one built against 7.0 (westlake/02-bridge.sh)'
json.dump(d, open(p, 'w'), indent=2, sort_keys=True)
print('  native runtime: liboh_adapter_bridge.so', hashlib.sha256(b).hexdigest()[:16])
EOF
fi
