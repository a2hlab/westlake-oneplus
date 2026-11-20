#!/bin/bash
# supervise-round.sh TAG [FIRST [LAST]]: run corpus round TAG (07-round.sh) to its end without a person.
#
# 07-round.sh resumes from logs/TAG/results.tsv and stops with exit 4 when the phone stops answering. Then: a phone
# in Qualcomm crash-dump mode (a hang) is captured and restarted by scripts/recover-phone.sh; a phone that rebooted
# by itself is waited for; either way 03-prep.sh and 04-framework.sh run again, and the round goes on. The app that
# was running is launched again; an app during which the phone stopped answering twice gets the result "phone-hung"
# and is skipped (a later RETRY=1 run would launch it again: finish-round.sh leaves those out). Ends when the round
# is done (exit 0), when /data is full (3), or after MAX_RESTARTS (40) restarts (1).
#
# Needs 07-round.sh's settings (westlake/local.sh), and a phone that starts OH by itself after a reset (oh-7.0
# branch: 13-flash-boot.sh; with /data on its own partition, 14-data-partition.sh, the Wi-Fi login stays too), or
# SERIAL and BOOT_IMG so that recover-phone.sh can RAM-boot it; recover-phone.sh's settings for the capture.
# WL_ENV=FILE: settings sourced (and exported) first, e.g. those of the 7.0 setup. Log: $WL_ROUND/supervise-TAG.log;
# 07-round.sh's output goes to $WL_ROUND/TAG.out. Start it detached: setsid nohup supervise-round.sh TAG >/dev/null &
# To stop a round: stop this script first (else it "recovers" the phone), then 07-round.sh.
# RECOVER=none: never run recover-phone.sh, only wait for the phone to come back. With two phones (README, "Two
# phones") a phone in crash-dump mode cannot be told from the other one, so only one phone's supervisor may reset it.
set -uo pipefail
[ -n "${WL_ENV:-}" ] && { set -a; . "$WL_ENV"; set +a; }
. "$(dirname "$0")/../config.sh"
wl_need WL_ROUND
TAG=${1:?usage: $0 TAG [FIRST [LAST]]}; FIRST=${2:-1}; LAST=${3:-100000}
R=$WL_ROUND; LOG=$R/supervise-$TAG.log; MAX_RESTARTS=${MAX_RESTARTS:-40}
RECOVER=${RECOVER:-$WL_DIR/../scripts/recover-phone.sh}
say() { echo "$(date '+%F %T') $*" | tee -a "$LOG"; }
s() { timeout 90 "$WL_HDC" -t "$HDC_TARGET" shell "$@" </dev/null 2>&1 | tr -d '\r'; }
booted() { [ "$(s 'param get bootevent.boot.completed' | tr -d '\n ')" = true ]; }
online() { [ -z "${NET_CHECK-8.8.8.8}" ] || s "ping -c 1 -W 3 ${NET_CHECK-8.8.8.8} >/dev/null 2>&1 && echo UP" | grep -q UP; }
mkdir -p "$R/logs/$TAG"

for n in $(seq 1 "$MAX_RESTARTS"); do
  say "round $TAG ranks $FIRST-$LAST: run $n"
  bash "$WL_DIR/07-round.sh" "$TAG" "$FIRST" "$LAST" >> "$R/$TAG.out" 2>&1
  rc=$?
  say "07-round.sh exit $rc"
  case $rc in
    0) say "round $TAG done"; exit 0 ;;
    3) say "round $TAG stopped: /data full"; exit 3 ;;
  esac
  # The app the phone went away during (07-round.sh names it); the second time it gets a result of its own.
  pkg=$(grep -a -o "hk-[A-Za-z0-9._]*: the phone stopped answering" "$R/round-$TAG.log" 2>/dev/null | tail -1 | cut -d: -f1)
  if [ -n "$pkg" ] && [ "$(grep -a -c "$pkg: the phone stopped answering" "$R/round-$TAG.log")" -ge 2 ] &&
     ! grep -q "^$pkg	" "$R/logs/$TAG/results.tsv" 2>/dev/null; then
    printf '%s\tphone-hung\tthe phone stopped answering twice while it ran\n' "$pkg" >> "$R/logs/$TAG/results.tsv"
    say "$pkg: the second time the phone went while it ran: phone-hung"
  fi
  sleep 30
  if [ "$RECOVER" != none ] && bash "$RECOVER" --check; then
    say "phone in crash-dump mode (running: ${pkg:-?}): recovering"
    bash "$RECOVER" >> "$LOG" 2>&1 || { say "recover-phone.sh failed (exit $?)"; continue; }
  else
    say "phone not answering, not in crash-dump mode: waiting for it"
    for _ in $(seq 1 90); do booted && break; sleep 20; done
    booted || { say "the phone did not come back"; continue; }
  fi
  sleep 60   # an unlock while the system is still starting can block SceneBoard
  { bash "$WL_DIR/03-prep.sh" && bash "$WL_DIR/04-framework.sh"; } >> "$LOG" 2>&1 || say "03-prep.sh or 04-framework.sh failed"
  for _ in $(seq 1 90); do online && break; sleep 20; done
  online && say "phone back online" || say "phone without network: the round waits for it or stops again"
done
say "round $TAG: $MAX_RESTARTS runs, giving up"; exit 1
