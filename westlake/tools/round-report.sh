#!/bin/bash
# round-report.sh TAG [BASE_SCORES]: the numbers of corpus round TAG so far (it may still run): scores its logs with
# round_score.py, compares them with another round's scores (BASE_SCORES: a round_score.py --json output, or the
# harness's lifecycle scores of a D600 round) with round_compare.py, and prints the headline: apps with a result,
# apps per rung, the apps whose rung differs, apps with GPU faults, results per status.
# Output in REPORT_DIR (default $WL_ROUND/report-TAG): TAG-scores.json, score.txt, compare.md.
set -uo pipefail
[ -n "${WL_ENV:-}" ] && { set -a; . "$WL_ENV"; set +a; }
. "$(dirname "$0")/../config.sh"
wl_need WL_ROUND WL_HARNESS
export WL_HARNESS
TAG=${1:?usage: $0 TAG [BASE_SCORES]}; BASE=${2:-}
L=$WL_ROUND/logs/$TAG; O=${REPORT_DIR:-$WL_ROUND/report-$TAG}; T=$WL_DIR/tools
[ -f "$L/results.tsv" ] || die "$L/results.tsv missing"
mkdir -p "$O"
python3 "$T/round_score.py" "$L" --json "$O/$TAG-scores.json" > "$O/score.txt" 2>&1 || { tail -3 "$O/score.txt"; exit 1; }
echo "== $TAG: $(wc -l < "$L/results.tsv") apps with a result"
grep '^rungs:' "$O/score.txt"
if [ -n "$BASE" ]; then
  python3 "$T/round_compare.py" "$O/$TAG-scores.json" "$BASE" --results "$L/results.tsv" --out "$O/compare.md" > /dev/null &&
    head -4 "$O/compare.md"
fi
echo "apps with GPU faults: $(grep -c 'GPU fault lines' "$WL_ROUND/round-$TAG.log" 2>/dev/null)"
cut -f2 "$L/results.tsv" | sort | uniq -c | tr '\n' ' '; echo
