#!/bin/bash
# Download the OpenHarmony prebuilts (toolchains, node, ...) and select Node 18.
set -euo pipefail
. "$(dirname "$0")/config.sh"
cd "$OH_ROOT"
unset CONDA_PREFIX CONDA_DEFAULT_ENV PYTHONPATH VIRTUAL_ENV

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
