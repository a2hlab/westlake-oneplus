#!/bin/bash
# Download the OpenHarmony prebuilts (toolchains, node, ...) and select Node 18.
set -euo pipefail
. "$(dirname "$0")/config.sh"
cd "$OH_ROOT"
unset CONDA_PREFIX CONDA_DEFAULT_ENV PYTHONPATH VIRTUAL_ENV

# OH 7.0's declgen_ts2sts npm postinstall (script/install_tsc.sh) clones TypeScript "master" from gitcode: unpinned,
# and gitcode's web firewall now refuses git clones (HTTP 418). The build itself packs the in-tree
# //third_party/typescript (declgen_ts2sts/compile_declgen.sh), so point that clone at the same pinned checkout.
if [ -f arkcompiler/runtime_core/static_core/plugins/ets/tools/declgen_ts2sts/script/install_tsc.sh ]; then
  ts_mirror="$WORK_DIR/mirrors/third_party_typescript.git"
  rm -rf "$ts_mirror"; mkdir -p "$(dirname "$ts_mirror")"; git init -q --bare "$ts_mirror"
  git -C "$ts_mirror" config receive.shallowUpdate true  # repo sync checkouts are shallow
  git -C third_party/typescript push -q "$ts_mirror" HEAD:refs/heads/master
  export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0="url.file://$ts_mirror.insteadOf" \
         GIT_CONFIG_VALUE_0=https://gitcode.com/openharmony/third_party_typescript.git
fi

step "prebuilts_download.sh"
bash build/prebuilts_download.sh --disable-rich

# The OH 6.1 build first builds the ohos-sdk; its npm steps need Node 18 (Node 14 resolves an lru-cache that no
# longer runs on it). jsframework keeps Node 14 through its own patch (patches/oh/third_party/jsframework).
step "nodejs current -> node-v18.20.1"
nd=prebuilts/build-tools/common/nodejs
[ -d "$nd/node-v18.20.1-linux-x64" ] || die "$nd/node-v18.20.1-linux-x64 missing after prebuilts download"
[ -d "$nd/node-v14.21.1-linux-x64" ] || die "$nd/node-v14.21.1-linux-x64 missing after prebuilts download"
ln -sfn node-v18.20.1-linux-x64 "$nd/current"
ls -l "$nd/current"
[ -x "$OH_CLANG_BIN/clang" ] || die "OpenHarmony clang not found at $OH_CLANG_BIN"
"$OH_CLANG_BIN/clang" --version | head -1
