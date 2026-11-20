#!/bin/bash
# Settings shared by every script. Override any of them in the environment or in scripts/local.sh (git-ignored).
SCRIPTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(dirname "$SCRIPTS_DIR")
[ -f "$SCRIPTS_DIR/local.sh" ] && . "$SCRIPTS_DIR/local.sh"

# --- where things live (~200 GB after a build, ccache up to 100 GB more: keep ~300 GB free) ---
: "${WORK_DIR:=$HOME/oh61-oneplus6}"
: "${OH_ROOT:=$WORK_DIR/src}"                         # OpenHarmony 6.1 repo client
: "${KERNEL_SRC:=$OH_ROOT/kernel/linux/linux-sdm845}"  # ohos_port linux-sdm845 (pinned in manifests/ohport.xml)
: "${KERNEL_OUT:=$WORK_DIR/kernel-out}"
: "${HOST_DIR:=$WORK_DIR/host}"                       # libtinfo5, mkbootimg, repo launcher
: "${IMAGES_DIR:=$OH_ROOT/out/fajita/packages/phone/images}"
: "${BOOT_IMG:=$WORK_DIR/boot-oneplus6.img}"
: "${BACKUP_DIR:=$WORK_DIR/phone-backup}"             # partitions saved by 10-install.sh

# --- sources ---
: "${OH_MANIFEST_URL:=https://gitee.com/openharmony/manifest.git}"
: "${OH_TAG:=OpenHarmony-v6.1-Release}"
MKBOOTIMG_URL=https://android.googlesource.com/platform/system/tools/mkbootimg
MKBOOTIMG_COMMIT=d2bb0af5ba6d3198a3e99529c97eda1be0b5a093
LIBTINFO5_URL=http://archive.ubuntu.com/ubuntu/pool/universe/n/ncurses/libtinfo5_6.3-2_amd64.deb
LIBTINFO5_SHA256=d2597b5aec92a930cf549e1b429ad892595813e72ec7814685ea146a9fb715e5

# --- build ---
: "${JOBS:=6}"            # ninja jobs: ArkUI compiles take 1-2 GB each; 6 fits in ~24 GB RAM
: "${SYNC_JOBS:=6}"
# ccache: hb puts it in $CCACHE_BASE/.ccache (default $HOME/.ccache, up to 100 GB); keep it with the tree
: "${CCACHE_BASE:=$WORK_DIR}"
: "${CCACHE_MAXSIZE:=100G}"
KERNEL_RELEASE=5.10.194-sdm845
OH_CLANG_BIN=$OH_ROOT/prebuilts/clang/ohos/linux-x86_64/llvm/bin
# Boot image layout of the OnePlus 6 bootloader (header v0, Image.gz + appended DTB).
# loglevel=1: only emergencies reach the screen's console. At 4, every kernel error was drawn on the framebuffer
# console (fbcon), and an app that made the kernel log ~50 errors a second (an access-token ioctl with the wrong
# magic, from apps' security SDKs probing their file descriptors) froze the phone into crash-dump mode within
# seconds, twice in a corpus round (TikTok, CapCut); at 1 the same apps ran. Boot debugging: BOOT_CMDLINE_EXTRA=ignore_loglevel.
# lsm=...,selinux,...: the kernel has SELinux built in, but its default LSM list (CONFIG_LSM) leaves it out.
BOOT_CMDLINE_BASE="console=tty0 fbcon=font:TER16x32 loglevel=1 hardware=fajita default_boot_device=soc@0/1d84000.ufshc ohos.boot.eng_mode=on lsm=lockdown,yama,loadpin,safesetid,integrity,selinux,bpf"
: "${BOOT_CMDLINE_EXTRA:=}"   # e.g. op6.logdump=1, or "ignore_loglevel" to see every boot message on screen
# Staged patch topics to apply and build with (patches/staging/<topic>, not yet run on the phone; empty: none).
: "${STAGING:=}"

# --- phone ---
: "${ADB:=adb}"
: "${FASTBOOT:=fastboot}"
: "${HDC:=hdc}"              # OpenHarmony device connector (from an OH SDK: toolchains/hdc)
: "${SERIAL:=}"              # adb/fastboot serial of the phone; empty = the only connected device
: "${HDC_TARGET:=A8HEV4DG4D5DH002083}"   # serial the board's USB config gives the OH gadget
SYSTEM_B_BYTES=2998927360     # OnePlus 6 system_b (sda14); the OH system image is 2684354560
VENDOR_B_BYTES=1073741824     # OnePlus 6 vendor_b (sde44)

# Windows tools (adb.exe/fastboot.exe/hdc.exe) called from WSL need Windows paths; \\wsl.localhost paths work,
# so files never have to be copied to a Windows drive.
is_win_tool() { case "$1" in *.exe|*.EXE) return 0 ;; esac; return 1; }
tool_path() {  # tool_path TOOL FILE -> FILE as that tool can open it
  local f; f=$(readlink -f "$2")
  if is_win_tool "$1"; then wslpath -w "$f"; else printf '%s\n' "$f"; fi
}
if [ -n "${WSL_DISTRO_NAME:-}" ] && { is_win_tool "$ADB" || is_win_tool "$FASTBOOT" || is_win_tool "$HDC"; }; then
  # Long-lived WSL shells can hold a dead interop socket ("UtilAcceptVsock ... accept4 failed 110": every .exe
  # call fails). Keep the current one if it answers, otherwise take the first one under /run/WSL that does.
  interop_ok() { (cd / && WSL_INTEROP=$1 timeout 5 cmd.exe /c exit 0 </dev/null >/dev/null 2>&1); }
  if [ -z "${WSL_INTEROP:-}" ] || ! interop_ok "$WSL_INTEROP"; then
    for s in $(ls -t /run/WSL/*_interop 2>/dev/null); do interop_ok "$s" && { export WSL_INTEROP=$s; break; }; done
  fi
fi
adb_()      { "$ADB" ${SERIAL:+-s "$SERIAL"} "$@" </dev/null; }
fastboot_() { "$FASTBOOT" ${SERIAL:+-s "$SERIAL"} "$@" </dev/null; }
hdc_()      { "$HDC" -t "$HDC_TARGET" "$@" </dev/null; }

die()  { echo "ERROR: $*" >&2; exit 1; }
step() { echo; echo "=== $* ==="; }
