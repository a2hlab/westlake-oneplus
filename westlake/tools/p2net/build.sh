#!/bin/bash
# build.sh: the binaries of the phone tunnel (README, "A phone without Wi-Fi") into P2NET_BUILD:
#   tapfwd       the phone side (aarch64, static musl), built from tapfwd.c with zig 0.13.0 (downloaded once,
#                checked against its published SHA-256)
#   passt-root/  passt, the PC side's user-space NAT (DHCP, DNS, TCP/UDP/ICMP), unpacked from Ubuntu's package
#                (apt-get download: no install, no root)
set -euo pipefail
B=${P2NET_BUILD:?set P2NET_BUILD: a directory for the tunnel binaries}
D=$(cd "$(dirname "$0")" && pwd)
ZIG_VERSION=0.13.0
ZIG_SHA256=d45312e61ebcc48032b77bc4cf7fd6915c11fa16e4aad116b66c9468211230ea   # zig-linux-x86_64-0.13.0.tar.xz
mkdir -p "$B"
if [ ! -x "$B/zig/zig" ]; then
  curl -sS -L -o "$B/zig.tar.xz" "https://ziglang.org/download/$ZIG_VERSION/zig-linux-x86_64-$ZIG_VERSION.tar.xz"
  echo "$ZIG_SHA256  $B/zig.tar.xz" | sha256sum -c -
  mkdir -p "$B/zig"; tar -xJf "$B/zig.tar.xz" -C "$B/zig" --strip-components=1; rm "$B/zig.tar.xz"
fi
if [ ! -x "$B/passt-root/usr/bin/passt" ]; then
  (cd "$B" && apt-get download passt && dpkg-deb -x passt_*.deb passt-root)
fi
ZIG_GLOBAL_CACHE_DIR=$B/zig-cache ZIG_LOCAL_CACHE_DIR=$B/zig-cache \
  "$B/zig/zig" cc -target aarch64-linux-musl -static -O2 -s -Wall -o "$B/tapfwd" "$D/tapfwd.c"
sha256sum "$B/tapfwd"
