#!/bin/bash
# Prepare the phone for Westlake. Run after EVERY boot of OH (/data is a RAM disk: everything below is gone
# at the next boot; the phone's partitions are not touched):
#   - the Westlake device tools call sha256sum and chcon, which this build's toybox lacks: a copy of
#     /system/bin with an openssl-based sha256sum and a no-op chcon (SELinux is disabled here) is
#     bind-mounted over /system/bin
#   - makes sure the kernel wake lock no_suspend is held: this kernel's suspend drops USB (hdc) and loops
#     (README.md, known limitations). Images after release v6.1.0.31-r2 take it at boot (board init.fajita.cfg)
#   - sets the Android identity apps see (android-identity.sh: the phone's own, a OnePlus 6)
#   - installs the Westlake host HAP ($WL_HOST)
set -euo pipefail
. "$(dirname "$0")/config.sh"
wl_need WL_HOST_HAP
t=$WL_DIR/tools

step "sha256sum and chcon"
if wl_hdc shell 'sha256sum /system/bin/sh' | tr -d '\r' | grep -qE '^[0-9a-f]{64}  /system/bin/sh$'; then
  echo "  already in place"
else
  wl_hdc file send "$(wl_tool_path "$t/sha256sum.sh")" /data/local/tmp/wl-sha256sum >/dev/null
  wl_hdc file send "$(wl_tool_path "$t/chcon.sh")" /data/local/tmp/wl-chcon >/dev/null
  # chcon: the no-op stand-in only where SELinux is off (images built with build_selinux have a real chcon)
  wl_hdc shell 'O=/data/local/tmp/wl-sysbin; rm -rf $O && cp -a /system/bin $O &&
    rm -f $O/sha256sum && cp /data/local/tmp/wl-sha256sum $O/sha256sum && chmod 755 $O/sha256sum &&
    { [ -e /sys/fs/selinux/enforce ] && [ -e /system/bin/chcon ] || { rm -f $O/chcon && cp /data/local/tmp/wl-chcon $O/chcon && chmod 755 $O/chcon; }; } &&
    [ "$(ls $O | wc -l)" = "$(ls /system/bin | wc -l)" ] &&
    mount --bind $O /system/bin && echo "  bind mount OK"' | tr -d '\r'
  wl_hdc shell 'sha256sum /system/bin/sh' | tr -d '\r' | grep -qE '^[0-9a-f]{64}  /system/bin/sh$' \
    || die "sha256sum still missing on the phone"
fi

step "no kernel suspend"
# OH's power key, and its sleep timer after the screen goes off, put the kernel in s2idle. Here that drops USB and loops:
# the modem (1e40000.ipa) wakes the kernel every few seconds and OH suspends it again, so hdc keeps dropping and the
# screen does not stay on. OH's suspend loop (power_host) waits while a kernel wake lock is held. The same lock name as
# the board's init.fajita.cfg: on images that take it at boot this changes nothing.
if wl_hdc shell 'cat /sys/power/wake_lock' | tr -d '\r' | grep -qw no_suspend; then
  echo "  already held (the image takes it at boot)"
else
  wl_hdc shell 'echo no_suspend > /sys/power/wake_lock; cat /sys/power/wake_lock' | tr -d '\r' | grep -qw no_suspend \
    && echo "  wake lock held" || die "could not take the wake lock"
fi

step "audio and compute DSPs: no automatic restart"
# 2026-11-19, round o70b: a hang read back from the phone's RAM ended while the kernel restarted the crashed audio DSP
# ("remoteproc-adsp: fatal error received: SFR Init: wdog or kernel error suspected"). The restart did not cause that
# hang (a bus error had begun before the DSP crashed, and the phone also hung with the restart off), but this 5.10
# kernel's restart is not safe (its SLIMbus driver lacks the restart handling of later kernels). Without it a DSP
# crash leaves the phone running, without sound until the next boot. The modem keeps its restart (Wi-Fi depends on
# it). Not kept across reboots.
# WL_NO_RECOVERY (adsp cdsp): the remoteprocs, by part of their name, whose restart is turned off. A phone whose modem
# crash-loops (a dead radio: "RF stuck in QLINK start state") adds 4080000.remoteproc, which stops the loop.
for w in ${WL_NO_RECOVERY:-adsp cdsp}; do
  case $w in *[!A-Za-z0-9._-]*) die "WL_NO_RECOVERY: '$w' is not a plain name" ;; esac
done
wl_hdc shell "for r in /sys/class/remoteproc/remoteproc*; do n=\$(cat \$r/name); for w in ${WL_NO_RECOVERY:-adsp cdsp}; do
    case \$n in *\$w*) d=/sys/kernel/debug/remoteproc/\${r##*/}/recovery; echo disabled > \$d && echo \"  \$n: \$(cat \$d)\" || echo \"  \$n: not changed\";;
  esac; done; done" | tr -d '\r'

# The phone's Android identity (a OnePlus 6), for Build.* and native property reads: android-identity.sh.
bash "$(dirname "$0")/android-identity.sh" || die "android-identity.sh failed"

step "host HAP $WL_HOST"
hap=$(wl_build "$WL_HOST_HAP"); [ -f "$hap" ] || die "$hap missing"
if wl_hdc shell "bm dump -n $WL_HOST" | grep -q '"bundleName"'; then
  echo "  already installed"
else
  (cd "$(dirname "$hap")" && wl_hdc install "$(basename "$hap")") | tr -d '\r' | tail -1
  # Right after a boot the bundle manager can list the new bundle a few seconds after the install returns.
  for _ in 1 2 3 4 5; do wl_hdc shell "bm dump -n $WL_HOST" | grep -q '"bundleName"' && break; sleep 2; done
  wl_hdc shell "bm dump -n $WL_HOST" | grep -q '"bundleName"' || die "host HAP did not install"
fi
