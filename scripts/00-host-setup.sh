#!/bin/bash
# Host setup for building OpenHarmony 6.1 + the sdm845 kernel on Ubuntu 22.04/24.04 x86_64.
#   sudo scripts/00-host-setup.sh      installs packages (needs root)
#   scripts/00-host-setup.sh           (as your user) fetches libtinfo5 + the repo launcher into $HOST_DIR
set -euo pipefail
. "$(dirname "$0")/config.sh"

if [ "$(id -u)" = 0 ]; then
  step "apt packages"
  dpkg --configure -a
  apt-get update
  apt-get install -y \
    git git-lfs curl wget python3 python3-pip python3-venv ruby default-jdk-headless \
    flex bison gperf bc zip unzip zlib1g-dev ccache cmake ninja-build m4 \
    autoconf automake autopoint libtool libtool-bin gettext pkg-config \
    gcc-multilib g++-multilib libc6-dev-i386 lib32ncurses-dev lib32stdc++6 lib32z1 lib32z1-dev libncurses-dev \
    x11proto-core-dev libx11-dev libgl1-mesa-dev libxcursor-dev libxrandr-dev libxinerama-dev \
    libxml2-utils xsltproc gnutls-bin device-tree-compiler genext2fs abootimg libelf-dev libssl-dev \
    cpio f2fs-tools e2fsprogs dwarves
  echo "packages done; now run this script again as your normal user"
  exit 0
fi

mkdir -p "$HOST_DIR/lib" "$HOST_DIR/bin"
step "libtinfo.so.5 (the mingw clang of the OH SDK build needs it; Ubuntu 24.04 dropped libtinfo5)"
if [ ! -e "$HOST_DIR/lib/libtinfo.so.5" ]; then
  deb="$HOST_DIR/$(basename "$LIBTINFO5_URL")"
  curl -fL -o "$deb" "$LIBTINFO5_URL"
  echo "$LIBTINFO5_SHA256  $deb" | sha256sum -c -
  tmp=$(mktemp -d); dpkg-deb -x "$deb" "$tmp"
  cp -a "$tmp"/lib/x86_64-linux-gnu/libtinfo.so.5* "$HOST_DIR/lib/"
  rm -rf "$tmp"
fi
ls -l "$HOST_DIR/lib/"

step "repo launcher"
if ! command -v repo >/dev/null && [ ! -x "$HOST_DIR/bin/repo" ]; then
  curl -fL -o "$HOST_DIR/bin/repo" https://storage.googleapis.com/git-repo-downloads/repo
  chmod +x "$HOST_DIR/bin/repo"
fi
git lfs install --skip-repo >/dev/null
echo "host ready. Add $HOST_DIR/bin to PATH if 'repo' is not installed system-wide."
