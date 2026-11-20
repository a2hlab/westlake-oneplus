#!/bin/bash
# finish-round.sh TAG [BASE_SCORES]: the end of a supervised corpus round. Waits until round TAG's first pass is over
# (its supervisor, supervise-round.sh TAG, has ended with "round TAG done"), launches again the apps that did not
# launch, except those that hung the phone twice (phone-hung: a plain RETRY=1 would hang the phone on them again and
# again), and then scores the round and compares it with BASE_SCORES (round-report.sh). Output in
# $WL_ROUND/report-TAG/ (finish.log, retry-list.txt, the report). Start it detached next to the supervisor:
#   setsid nohup finish-round.sh TAG BASE >/dev/null 2>&1 &
# RETRY_RESTARTS (8): the retry pass's MAX_RESTARTS.
# MERGE_FROM=DIR: the round is shared with a second phone whose share runs in round directory DIR (README, "Two
# phones"). Its supervisor also counts as round TAG's, so this waits for both; then merge-round.sh brings DIR's
# results in, and a completion pass on this phone launches the apps that neither phone reached (start this script
# without LIST), before the retry pass and the report.
set -uo pipefail
[ -n "${WL_ENV:-}" ] && { set -a; . "$WL_ENV"; set +a; }
. "$(dirname "$0")/../config.sh"
wl_need WL_ROUND
TAG=${1:?usage: $0 TAG [BASE_SCORES]}; BASE=${2:-}
R=$WL_ROUND; OUT=$R/report-$TAG; T=$WL_DIR/tools; mkdir -p "$OUT"
say() { echo "$(date '+%F %T') $*" | tee -a "$OUT/finish.log"; }
running() { pgrep -f "^([^ ]*/)?bash [^ ]*supervise-round\.sh $TAG( |\$)" >/dev/null; }   # the supervisor itself
while running; do sleep 120; done
last=$(tail -1 "$R/supervise-$TAG.log" 2>/dev/null)
say "first pass over: $last"
case $last in *"round $TAG done"*) ;; *) say "the first pass did not finish: stopping here"; exit 1 ;; esac
if [ -n "${MERGE_FROM:-}" ]; then
  say "the other phone's share: $(tail -1 "$MERGE_FROM/supervise-$TAG.log" 2>/dev/null)"
  bash "$T/merge-round.sh" "$TAG" "$MERGE_FROM" 2>&1 | tee -a "$OUT/finish.log"
  MAX_RESTARTS=${RETRY_RESTARTS:-8} bash "$T/supervise-round.sh" "$TAG"
  last=$(tail -1 "$R/supervise-$TAG.log" 2>/dev/null)
  say "completion pass over: $last"
  case $last in *"round $TAG done"*) ;; *) say "the completion pass did not finish: stopping here"; exit 1 ;; esac
fi

RES=$R/logs/$TAG/results.tsv
awk -F'\t' '$2 == "launched" { ok[$1] = 1 } $2 == "phone-hung" { hung[$1] = 1 } { seen[$1] = 1 }
  END { for (p in seen) if (!ok[p] && !hung[p]) print substr(p, 4) }' "$RES" | sort > "$OUT/retry-list.txt"
say "retrying $(wc -l < "$OUT/retry-list.txt") apps (phone-hung ones left out)"
if [ -s "$OUT/retry-list.txt" ]; then
  RETRY=1 LIST=$OUT/retry-list.txt MAX_RESTARTS=${RETRY_RESTARTS:-8} bash "$T/supervise-round.sh" "$TAG"
  say "retry pass over: $(tail -1 "$R/supervise-$TAG.log")"
fi
REPORT_DIR=$OUT bash "$T/round-report.sh" "$TAG" ${BASE:+"$BASE"} >> "$OUT/finish.log" 2>&1
say "scored: $(grep '^rungs:' "$OUT/score.txt" 2>/dev/null)"
say "done"
