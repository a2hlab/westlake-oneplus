#!/bin/bash
# Stage the Westlake framework (ART, core libraries, Android framework, boot image, resources) on the phone and
# check that it initialises there. Run after 03-prep.sh, again after every boot.
# Without --contracts: the contract suite needs a network (the phone has none until Wi-Fi is set up), and the
# app launch only needs the preload to pass.
set -euo pipefail
. "$(dirname "$0")/config.sh"
wl_need WL_SC WL_APPSPAWN WL_CORE_RUNTIME WL_CORE_JAVA WL_JAVA_EXT WL_FRAMEWORK WL_BOOT WL_RES WL_DATA
[ -d "$WL_OUT/native-runtime-op6" ] && [ -f "$WL_OUT/op6-firmware-abi.json" ] || die "run 01-phone-runtime.sh first"
probe=$WL_SC/workspace/manifest/tools/probe_framework_vm.py
out=$WL_OUT/framework; rm -rf "$out"
uses=(); for u in ${WL_USES_LIBS:-}; do uses+=(--uses-library-build "$(wl_build "$u")"); done

step "framework -> phone"
wl_hdc shell 'rm -rf /data/local/tmp/a2hlab-framework-*' >/dev/null
cd "$WL_SC"
python3 "$probe" --appspawn-build "$(wl_build "$WL_APPSPAWN")" --core-runtime "$(wl_build "$WL_CORE_RUNTIME")" \
  --native-runtime "$WL_OUT/native-runtime-op6" --core-build "$(wl_build "$WL_CORE_JAVA")" \
  --extension-build "$(wl_build "$WL_JAVA_EXT")" --framework-build "$(wl_build "$WL_FRAMEWORK")" \
  --boot-build "$(wl_build "$WL_BOOT")" --resources-build "$(wl_build "$WL_RES")" \
  --firmware-abi "$WL_OUT/op6-firmware-abi.json" "${uses[@]}" --data-build "$(wl_build "$WL_DATA")" \
  --hdc "$WL_HDC" --serial "$HDC_TARGET" --out "$out" > "$out.log" 2>&1 || { tail -20 "$out.log"; die "framework probe failed"; }
python3 -I - "$out/device-report.json" <<'EOF'
import json, sys
d = json.load(open(sys.argv[1]))
print('  passed:', d.get('passed'), ' files:', len(d.get('files', {})), ' stage:', d.get('stage'))
sys.exit(0 if d.get('passed') else 1)
EOF
