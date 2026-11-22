#!/bin/bash
# kmsg-watch.sh TAG: while round TAG's supervisor (supervise-round.sh TAG) runs, read the phone's kernel log every
# 5 s and append the new lines, without SELinux audit lines and purgemm noise, to $WL_ROUND/report-TAG/kmsg-watch.log,
# so that a hang leaves its last lines on the host even when no RAM capture can be made. One small hdc shell call per
# 5 s; the round is not touched.
#
# A crash of the audio or compute DSP is answered with a reboot (REBOOT_ON_DSP_CRASH=0: not): 03-prep.sh turns their
# automatic restart off (this 5.10 kernel's restart path is not safe), which leaves the phone without sound until
# the next boot. The round then sees the phone go, and the supervisor resumes it after the boot.
# Start it detached next to the supervisor: setsid nohup kmsg-watch.sh TAG >/dev/null 2>&1 &
# KMSG_INTERVAL (5): seconds between reads. On a PC whose Windows hdc.exe also serves another session's round, keep
# it at 30 or more: every hdc.exe start goes through WSL interop, and their timeouts rise with the call rate.
set -uo pipefail
[ -n "${WL_ENV:-}" ] && { set -a; . "$WL_ENV"; set +a; }
. "$(dirname "$0")/../config.sh"
wl_need WL_ROUND
TAG=${1:?usage: $0 TAG}; O=$WL_ROUND/report-$TAG/kmsg-watch.log; mkdir -p "$(dirname "$O")"
s() { timeout "${2:-10}" "$WL_HDC" -t "$HDC_TARGET" shell "$1" </dev/null 2>/dev/null | tr -d '\r'; }
last=""; down=0
# The supervisor itself (bash running supervise-round.sh TAG), not a shell whose command line merely names it.
while pgrep -f "^([^ ]*/)?bash [^ ]*supervise-round\.sh $TAG( |\$)" >/dev/null; do
  out=$(s 'dmesg | tail -n 80' | grep -E '^\[ *[0-9]+\.[0-9]+\]')
  if [ -n "$out" ]; then
    [ $down = 1 ] && { echo "$(date '+%F %T') phone answers again" >> "$O"; last=""; }
    down=0
    if [ -n "$last" ] && printf '%s\n' "$out" | grep -qxF "$last"; then
      new=$(printf '%s\n' "$out" | awk -v l="$last" 'f { print } $0 == l { f = 1 }')
    else
      new=$out
    fi
    printf '%s\n' "$new" | grep -v -E 'audit: type=1400|kauditd_printk_skb|purgemm:' | grep -v '^$' >> "$O"
    last=$(printf '%s\n' "$out" | tail -1)
    if [ "${REBOOT_ON_DSP_CRASH:-1}" = 1 ] && printf '%s\n' "$new" | grep -q -E 'crash detected in remoteproc-(adsp|cdsp)'; then
      echo "$(date '+%F %T') DSP crash: rebooting the phone" >> "$O"
      s 'sync; reboot' 20 >/dev/null
      sleep 60
    fi
  elif [ $down = 0 ]; then
    echo "$(date '+%F %T') phone does not answer" >> "$O"; down=1
  fi
  sleep "${KMSG_INTERVAL:-5}"
done
echo "$(date '+%F %T') supervisor gone: stop" >> "$O"
