#!/bin/bash
# Make Westlake's native runtime fit this phone. Run once per OH build, with the phone in OH (hdc up):
#   1. pulls the OH libraries Westlake links against (the firmware list of westlake native/oh61-firmware-abi.json)
#   2. writes $WL_OUT/op6-firmware-abi.json: the same list with the phone's hashes, without the board's GPU
#      driver libGLES_mali.z.so (this phone has an Adreno; OH's EGL/GLES drive Mesa freedreno)
#   3. builds libGLES_mali.z.so, an empty stand-in that depends on OH's libEGL.so, libGLESv3.so and
#      libbuffer_handle.z.so (the only names Westlake's libhwui/libandroid/libGLESv1_CM take from the Mali file)
#   4. copies the native runtime to $WL_OUT/native-runtime-op6 with the stand-in added
set -euo pipefail
. "$(dirname "$0")/config.sh"
wl_need WL_SC WL_WESTLAKE WL_NATIVE_RUNTIME
abi=$WL_WESTLAKE/$WL_FIRMWARE_ABI; [ -f "$abi" ] || die "$abi missing"
clang=$WL_SC/workspace/toolchains/ohos-sdk/native/llvm/bin/clang; [ -x "$clang" ] || die "$clang missing"
fw=$WL_OUT/phone-fw; mkdir -p "$fw"

step "pull the phone's libraries"
paths=$(python3 -I -c 'import json,sys; [print(e["path"]) for n,e in json.load(open(sys.argv[1]))["firmware"].items() if n != "libGLES_mali.z.so"]' "$abi")
paths="$paths /system/lib64/platformsdk/libEGL.so /system/lib64/platformsdk/libGLESv3.so /system/lib64/chipset-sdk-sp/libbuffer_handle.z.so"
n=0
for p in $paths; do
  mkdir -p "$fw$(dirname "$p")"
  wl_hdc file recv "$p" "$(wl_tool_path "$fw$(dirname "$p")")/$(basename "$p")" >/dev/null
  [ -s "$fw$p" ] || die "could not pull $p"
  n=$((n + 1))
done
echo "  $n libraries in $fw"

step "firmware list with the phone's hashes -> $WL_OUT/op6-firmware-abi.json"
python3 -I - "$abi" "$fw" "$WL_OUT/op6-firmware-abi.json" <<'EOF'
import hashlib, json, sys
src, fw, out = sys.argv[1:4]
d = json.load(open(src)); e = d['firmware']; changed = 0
e.pop('libGLES_mali.z.so', None)
for name, entry in e.items():
    h = hashlib.sha256(open(fw + entry['path'], 'rb').read()).hexdigest()
    changed += h != entry['sha256']; entry['sha256'] = h
d['scope'] += (' OnePlus 6 copy: hashes of the OH build on the phone; libGLES_mali.z.so is not firmware there '
               '(the runtime ships a stand-in).')
json.dump(d, open(out, 'w'), indent=1, sort_keys=True)
print(f'  {len(e)} libraries, {changed} differ from the board build')
EOF

step "libGLES_mali.z.so stand-in"
g=$WL_OUT/glstub; mkdir -p "$g"
cat > "$g/libGLES_mali_stub.c" <<'EOF'
/* Westlake on the OnePlus 6: stands in for the board's Mali driver, libGLES_mali.z.so. Westlake's libraries
 * take only standard EGL/GLES entry points and AllocateBufferHandle/FreeBufferHandle from it; the three
 * libraries recorded as dependencies export them, so the loader finds them. No code. */
EOF
l=$fw/system/lib64
"$clang" --target=aarch64-linux-ohos -shared -nostdlib -fuse-ld=lld -o "$g/libGLES_mali.z.so" "$g/libGLES_mali_stub.c" \
  -Wl,-soname,libGLES_mali.z.so -Wl,--no-as-needed \
  "$l/platformsdk/libEGL.so" "$l/platformsdk/libGLESv3.so" "$l/chipset-sdk-sp/libbuffer_handle.z.so"

step "native runtime copy -> $WL_OUT/native-runtime-op6"
r=$WL_OUT/native-runtime-op6; rm -rf "$r"; cp -a "$(wl_build "$WL_NATIVE_RUNTIME")" "$r"; cp "$g/libGLES_mali.z.so" "$r/"
python3 -I - "$r" <<'EOF'
import hashlib, json, os, sys
r = sys.argv[1]; p = os.path.join(r, 'artifacts.json'); d = json.load(open(p))
b = open(os.path.join(r, 'libGLES_mali.z.so'), 'rb').read()
d['artifacts']['libGLES_mali.z.so'] = {'bytes': len(b), 'sha256': hashlib.sha256(b).hexdigest()}
d['scope'] += ('; OnePlus 6 copy: plus libGLES_mali.z.so, a stand-in for the Mali driver that depends on OH '
               'libEGL.so, libGLESv3.so and libbuffer_handle.z.so')
json.dump(d, open(p, 'w'), indent=2, sort_keys=True)
print('  artifacts:', len(d['artifacts']))
EOF
