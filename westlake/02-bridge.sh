#!/bin/bash
# Build Westlake's window/ability bridge (liboh_adapter_bridge.so) from $WL_WESTLAKE, which must carry the
# classic-window-manager fix: this OH build has no SceneBoard, so the bridge creates windows through the
# legacy IWindowManager, where the activity's sub-window needs the host window as parent and no OH window
# animation. Writes $WL_OUT/override-op6: a copy of $WL_OVERRIDE with this bridge.
set -euo pipefail
. "$(dirname "$0")/config.sh"
wl_need WL_SC WL_WESTLAKE WL_OVERRIDE WL_NATIVE_RUNTIME
grep -q 'legacy SUB_WINDOW parent' "$WL_WESTLAKE/framework/window/jni/oh_window_manager_client.cpp" \
  || die "$WL_WESTLAKE lacks the classic-window-manager fix (see westlake/README.md)"
ws=$WL_SC/workspace; b=$WL_OUT/bridge; rm -rf "$b"; mkdir -p "$b"
cd "$WL_WESTLAKE"

step "compile the bridge sources (native/bridge15-sources.json)"
python3 tools/compile_native_inventory.py --workspace "$ws" --inventory native/bridge15-sources.json \
  --westlake-source "$WL_WESTLAKE" --header-build "$WL_SC/imports/oh61-bridge-headers" --out "$b/objects" | tail -1
printf '{"liboh_adapter_bridge.so": {"build": "%s"}}\n' "$b/objects" > "$b/map.json"

step "link"
python3 tools/build_native_imports.py --workspace "$ws" --firmware-abi native/oh61-firmware-abi.json \
  --object-map "$b/map.json" --out "$b/imports" | tail -1
python3 tools/link_native_platform.py --workspace "$ws" --object-map "$b/map.json" --imports "$b/imports" \
  --core-runtime "$(wl_build "$WL_NATIVE_RUNTIME")" --out "$b/link" | tail -1
lib=$b/link/liboh_adapter_bridge.so; [ -s "$lib" ] || die "no $lib"

step "override -> $WL_OUT/override-op6"
o=$WL_OUT/override-op6; rm -rf "$o"; cp -a "$(wl_build "$WL_OVERRIDE")" "$o"; cp "$lib" "$o/lib/"
python3 -I - "$o" "$(git -C "$WL_WESTLAKE" rev-parse --short HEAD)" <<'EOF'
import hashlib, json, os, sys
o, rev = sys.argv[1:3]; p = os.path.join(o, 'artifacts.json'); d = json.load(open(p))
h = hashlib.sha256(open(os.path.join(o, 'lib/liboh_adapter_bridge.so'), 'rb').read()).hexdigest()
d['artifacts']['liboh_adapter_bridge.so']['sha256'] = h
d['description'] = d.get('description', '') + '; OnePlus 6: liboh_adapter_bridge.so from westlake ' + rev
d.setdefault('notes', []).append('OnePlus 6 copy: liboh_adapter_bridge.so ' + h[:8] + ' from westlake ' + rev +
                                 ' (classic window manager)')
json.dump(d, open(p, 'w'), indent=2)
print('  liboh_adapter_bridge.so', h[:16])
EOF
