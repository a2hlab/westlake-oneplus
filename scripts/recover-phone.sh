#!/bin/bash
# recover-phone.sh [--check]: a phone that hung or panicked under OH waits in Qualcomm crash-dump mode (USB 05c6:900e,
# "QUSB_BULK" on Windows) with its RAM intact, until it is restarted. This saves what the kernel left there, restarts
# the phone and waits until OpenHarmony has booted again. Nothing is written to the phone.
#
#   1. crashdump.py kmsg: the kernel's own log (every message, whatever the console loglevel), the per-CPU printk
#      buffers, all tasks, run queues and the stacks of running and blocked tasks, the reset-reason regions, and
#      TrustZone's and the AOP's diagnostics (ram/tzdiag.txt) -> CRASH_DIR/panic-<time>/ (dmesg-ram.txt, ram/)
#   2. crashdump.py console: the ramoops console zone (console.txt), then reset
#   3. the phone restarts. With OH in boot_b (oh-7.0 branch: 13-flash-boot.sh) it starts OH by itself; a phone that
#      comes back in Android or fastboot instead is RAM-booted with 11-boot-oh.sh (BOOT_IMG), but only when SERIAL
#      names it, so that no other phone is ever touched. Then it waits for boot completion.
#
#   --check   only say whether a phone is in crash-dump mode (exit 0) or not (exit 1)
# Exit 0: OH is up again; 1: no phone in crash-dump mode, or OH could not be started; 2: OH did not finish booting.
#
# Settings (scripts/local.sh or the environment), besides config.sh's phone tools:
#   CRASH_DIR         where captures and recover.log go (default $WORK_DIR/crashdumps)
#   CRASHDUMP_PYTHON  a python3 with pyusb and libusb-1.0 (default python3)
#   KERNEL_SYMS       a directory with the RUNNING kernel's System.map (else only the console is read), optionally its
#                     offsets.json (`crashdump.py offsets vmlinux > offsets.json`: tasks and stacks) and banner.txt
#                     (its "Linux version ..." line, checked against RAM). Default: $KERNEL_OUT, where
#                     04-build-kernel.sh leaves System.map and vmlinux
#   USBIPD            on WSL: usbipd-win's usbipd.exe (default: usbipd.exe on the PATH). Each crash-dump session
#                     needs the device attached afresh (detach, unbind, bind, attach --wsl; bind needs an
#                     administrator once), and its device node is made writable with `wsl.exe -u root chmod`.
#                     On Linux the node must be writable already (a udev rule for 05c6:900e)
#   RECOVER_BOOT_WAIT seconds to wait for OH's boot completion (default 900)
# On WSL, HDC may be westlake/tools/hdc-retry.sh (with HDC_EXE), which repeats calls a dead interop socket dropped.
set -uo pipefail
. "$(dirname "$0")/config.sh"
: "${CRASH_DIR:=$WORK_DIR/crashdumps}"
: "${CRASHDUMP_PYTHON:=python3}"
: "${KERNEL_SYMS:=$KERNEL_OUT}"
: "${RECOVER_BOOT_WAIT:=900}"
CD=$SCRIPTS_DIR/crashdump.py
ID=05c6:900e
WSL=; [ -n "${WSL_DISTRO_NAME:-}" ] && WSL=1
[ -n "$WSL" ] && : "${USBIPD:=$(command -v usbipd.exe 2>/dev/null)}"
: "${USBIPD:=}"

usbipd_() { (cd / && timeout 120 "$USBIPD" "$@" </dev/null 2>/dev/null | tr -d '\r'); }
busid() { usbipd_ list | awk -v id="$ID" '$2 == id { print $1; exit }'; }
in_crashdump() { if [ -n "$USBIPD" ]; then [ -n "$(busid)" ]; else lsusb -d "$ID" >/dev/null 2>&1; fi; }

if [ "${1:-}" = --check ]; then in_crashdump; exit; fi

mkdir -p "$CRASH_DIR"; LOG=$CRASH_DIR/recover.log
say() { echo "$(date '+%F %T') $*" | tee -a "$LOG"; }

attach() {   # a fresh Sahara session: (re)attach the crash-dump device to WSL; its node writable
  local b d
  if [ -n "$USBIPD" ]; then
    b=$(busid); [ -n "$b" ] || return 1
    usbipd_ detach --busid "$b" >/dev/null; sleep 2
    usbipd_ unbind --busid "$b" >/dev/null; sleep 3
    usbipd_ bind --busid "$b" >/dev/null
    usbipd_ attach --wsl --busid "$b" >/dev/null; sleep 3
  fi
  d=$(lsusb -d "$ID" 2>/dev/null | sed -nE 's#^Bus ([0-9]+) Device ([0-9]+).*#/dev/bus/usb/\1/\2#p' | head -1)
  [ -n "$d" ] || { say "no $ID device in Linux"; return 1; }
  [ -w "$d" ] && return 0
  if [ -n "$WSL" ]; then (cd / && timeout 60 wsl.exe -d "$WSL_DISTRO_NAME" -u root -- chmod a+rw "$d" </dev/null >/dev/null 2>&1); fi
  [ -w "$d" ] || { say "$d is not writable (a udev rule for $ID, or root)"; return 1; }
}

capture() {  # capture DIR: best effort, never fails
  local o=$1 a=() r
  mkdir -p "$o/ram"
  if [ -s "$KERNEL_SYMS/System.map" ]; then
    a=(--system-map "$KERNEL_SYMS/System.map")
    [ -s "$KERNEL_SYMS/offsets.json" ] && a+=(--offsets "$KERNEL_SYMS/offsets.json")
    [ -s "$KERNEL_SYMS/banner.txt" ] && a+=(--banner "$KERNEL_SYMS/banner.txt")
    if attach; then
      timeout 420 "$CRASHDUMP_PYTHON" "$CD" kmsg "$o" "${a[@]}" --no-image --budget 360 > "$o/ram/kmsg.out" 2> "$o/ram/kmsg.err"
      r=$(tail -1 "$o/ram/kmsg.out" 2>/dev/null | cut -c1-300); say "${r:-kmsg: no result (ram/kmsg.err)}"
    fi
  else
    say "no $KERNEL_SYMS/System.map (KERNEL_SYMS): the kernel's own log is not read"
  fi
  attach && timeout 300 "$CRASHDUMP_PYTHON" "$CD" console "$o" 2>&1 | tail -1 | tee -a "$LOG"
  # The last kernel messages without the usual noise, the TrustZone interrupts that fired, blocked tasks.
  grep -a -v -E 'access tokenid magic fail|audit: type=1400|kauditd_printk_skb' "$o/dmesg-ram.txt" 2>/dev/null |
    tail -4 | cut -c1-220 | tee -a "$LOG"
  grep -a -E 'fired|type 0x[1-9a-f]' "$o/ram/tzdiag.txt" 2>/dev/null | head -8 | tee -a "$LOG"
  grep -a -E '^watchdog_service|^D: ' "$o/ram/summary.txt" 2>/dev/null | head -6 | tee -a "$LOG"
  tail -c 3000 "$o/console.txt" 2>/dev/null | grep -a -E 'gpu fault|Unhandled context|panic|watchdog|Oops' | tail -3 |
    tee -a "$LOG"
  return 0
}

hdc_state() { timeout 30 "$HDC" list targets -v </dev/null 2>/dev/null | tr -d '\r' | awk -v t="$HDC_TARGET" '$1 == t { print $3 }'; }
booted() { [ "$(timeout 60 "$HDC" -t "$HDC_TARGET" shell 'param get bootevent.boot.completed' </dev/null 2>/dev/null |
  tr -d '\r\n ')" = true ]; }

in_crashdump || { say "no phone in crash-dump mode"; exit 1; }
out=$CRASH_DIR/panic-$(date +%Y%m%d-%H%M%S)
say "crash-dump mode: saving what the kernel left in RAM to $out"
capture "$out"
say "resetting"
attach && timeout 60 "$CRASHDUMP_PYTHON" "$CD" reset 2>&1 | tail -1 | tee -a "$LOG"
sleep 20

# Back in OH (hdc), or in Android or fastboot (only this phone's SERIAL counts: an error text is output too).
h= a= f=
for _ in $(seq 1 60); do
  h=$(hdc_state)
  if [ -n "$SERIAL" ]; then
    f=$(timeout 30 "$FASTBOOT" devices </dev/null 2>/dev/null | tr -d '\r' | grep -E "^$SERIAL[[:space:]]+fastboot$")
    a=$(timeout 30 "$ADB" devices </dev/null 2>/dev/null | tr -d '\r' | grep -E "^$SERIAL[[:space:]]+device$")
  fi
  [ "$h" = Connected ] || [ -n "$f$a" ] && break
  sleep 10
done
say "phone back: hdc ${h:-none}, fastboot $([ -n "$f" ] && echo yes || echo no), adb $([ -n "$a" ] && echo yes || echo no)"
if [ "$h" != Connected ]; then
  [ -n "$SERIAL" ] || { say "no OH after the reset; with SERIAL set, a phone back in Android or fastboot is RAM-booted"; exit 1; }
  [ -n "$f$a" ] || { say "the phone did not come back (hold Power ~10 s)"; exit 1; }
  say "not in OH: RAM-booting it ($BOOT_IMG)"
  bash "$SCRIPTS_DIR/11-boot-oh.sh" >> "$LOG" 2>&1 || { say "11-boot-oh.sh failed"; exit 1; }
fi
for _ in $(seq 1 $((RECOVER_BOOT_WAIT / 10))); do booted && break; sleep 10; done
booted || { say "OH did not finish booting within $RECOVER_BOOT_WAIT s"; exit 2; }
say "OH is up (capture: $out)"
