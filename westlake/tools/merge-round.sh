#!/bin/bash
# merge-round.sh TAG OTHER_ROUND_DIR: bring round TAG's results from another round directory (a second phone's share
# of the round, README "Two phones") into this one ($WL_ROUND): for every app that has no line in this round's
# logs/TAG/results.tsv yet, its lines from OTHER_ROUND_DIR/logs/TAG/results.tsv are appended and its files there
# (hk-<package>.*: log, hilog, screenshot, process map, crash dump, ...) are copied. Apps this round already has keep
# their own results. Run it when neither round's runner is going (both supervisors have ended).
set -uo pipefail
[ -n "${WL_ENV:-}" ] && { set -a; . "$WL_ENV"; set +a; }
. "$(dirname "$0")/../config.sh"
wl_need WL_ROUND
TAG=${1:?usage: $0 TAG OTHER_ROUND_DIR}; OTHER=${2:?usage: $0 TAG OTHER_ROUND_DIR}
DST=$WL_ROUND/logs/$TAG; SRC=$OTHER/logs/$TAG
[ -s "$SRC/results.tsv" ] || die "$SRC/results.tsv: nothing to merge"
[ "$(readlink -f "$SRC")" != "$(readlink -f "$DST")" ] || die "$SRC is this round's own log directory"
mkdir -p "$DST"; touch "$DST/results.tsv"
n=0; files=0
for app in $(cut -f1 "$SRC/results.tsv" | sort -u); do
  grep -q "^$app	" "$DST/results.tsv" && continue
  grep "^$app	" "$SRC/results.tsv" >> "$DST/results.tsv"
  for f in "$SRC/$app".*; do
    [ -e "$f" ] || continue
    [ -e "$DST/$(basename "$f")" ] || { cp -p "$f" "$DST/"; files=$((files + 1)); }
  done
  n=$((n + 1))
done
echo "merged $n apps ($files files) from $SRC into $DST"
