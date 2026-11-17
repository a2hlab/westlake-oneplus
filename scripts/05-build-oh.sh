#!/bin/bash
# Build the OpenHarmony 6.1 images for product fajita (system.img, vendor.img, ramdisk.img, ...).
# First build: several hours (it also builds the ohos-sdk); peak RAM grows with JOBS.
set -euo pipefail
. "$(dirname "$0")/config.sh"
[ -f "$KERNEL_OUT/.modules-installed" ] || die "run 04-build-kernel.sh first (system.img packs its modules)"

# A clean environment: a conda/venv python or ruby on PATH breaks parts of the SDK build.
unset CONDA_PREFIX CONDA_DEFAULT_ENV PYTHONPATH VIRTUAL_ENV
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$HOST_DIR/bin
export LD_LIBRARY_PATH=$HOST_DIR/lib      # libtinfo.so.5 for the mingw clang (00-host-setup.sh)
export CCACHE_BASE CCACHE_MAXSIZE         # cache in $CCACHE_BASE/.ccache, not in $HOME
cd "$OH_ROOT"

# --deps-guard false: the post-build dependency-policy check (deps_guard, Passthrough rules) fails for this product.
#   It runs after the images are written and does not change them.
# allow_sanitize_debug=true: the port's components otherwise trip a CFI-sanitize assert in gn.
# hb ignores --jobs; the ninja job count goes through --ninja-args.
step "build.sh --product-name fajita"
./build.sh --product-name fajita --ccache --ninja-args=-j"$JOBS" --gn-args allow_sanitize_debug=true --deps-guard false

for f in system.img vendor.img ramdisk.img; do [ -s "$IMAGES_DIR/$f" ] || die "$IMAGES_DIR/$f missing"; done
ls -l "$IMAGES_DIR"/{system,vendor,ramdisk}.img
