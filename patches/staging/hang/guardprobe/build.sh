#!/bin/bash
# build.sh [OUT_DIR]: guardprobe.ko (guardprobe.c: does a read of this physical address complete?) for the kernel that
# 04-build-kernel.sh built (KERNEL_SRC and KERNEL_OUT, only read). Load it only into that kernel: the module carries
# its version magic, and this kernel has no module versioning to catch a mismatch. The build runs in OUT_DIR
# (default $WORK_DIR/guardprobe), so the checkout stays clean. On the phone, as root, e.g. for the first page of the
# 26 MB that the port's memory map gave the kernel (kernel 0011, docs/hang-2026-11-19.md):
#   hdc file send OUT_DIR/guardprobe.ko /data/local/tmp/
#   hdc shell 'insmod /data/local/tmp/guardprobe.ko addr=0x89100000; dmesg | grep guardprobe'
# "read completed": the page is readable. No answer and the phone in crash-dump mode: the firmware protects it (the
# main branch's scripts/crashdump.py reads the kernel's log from RAM, its recover-phone.sh restarts the phone).
# "not in the kernel's memory map": the kernel does not use that address as RAM (0x89100000 with kernel 0011).
# Pick addresses from /proc/iomem ("System RAM") and compare with the device tree's reserved-memory nodes.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/../../../../scripts/config.sh"
O=${1:-$WORK_DIR/guardprobe}
[ -x "$OH_CLANG_BIN/clang" ] || die "OpenHarmony clang not found at $OH_CLANG_BIN (run 02-prebuilts.sh)"
[ -s "$KERNEL_OUT/Module.symvers" ] || die "no kernel build in $KERNEL_OUT (run 04-build-kernel.sh)"
mkdir -p "$O"; O=$(cd "$O" && pwd)
cp "$here/guardprobe.c" "$here/Makefile" "$O/"
export PATH="$OH_CLANG_BIN:$PATH"
make -C "$KERNEL_SRC" O="$KERNEL_OUT" M="$O" ARCH=arm64 LLVM=1 LLVM_IAS=1 CC=clang HOSTCC=clang LOCALVERSION= modules
v=$(grep -a -o -m1 'vermagic=[[:print:]]*' "$O/guardprobe.ko" | head -1 || true)
echo "$O/guardprobe.ko: ${v:-no vermagic found}"
