#!/usr/bin/env python3
"""round_compare.py PHONE_SCORES D600_SCORES [--results RESULTS_TSV] [--out REPORT.md]: the phone round beside a
D600 round, app by app. Both are --json outputs of the scorers (tools/round_score.py for the phone, the harness's
westlake_gap.lifecycle for the D600). Prints how many apps reached each rung on each, and lists the apps whose rung
differs (phone lower first), with each side's blocker. RESULTS_TSV (07-round.sh's logs/TAG/results.tsv) adds the
apps the phone never launched (bundle or install failures) and why."""
import argparse
import json
from collections import Counter
from pathlib import Path

RUNGS = ('spawned', 'runtime-init', 'bound', 'activity', 'view', 'drawing')

parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
parser.add_argument('phone', type=Path)
parser.add_argument('d600', type=Path)
parser.add_argument('--results', type=Path)
parser.add_argument('--out', type=Path)
args = parser.parse_args()

phone = {s['app']: s for s in json.loads(args.phone.read_text())}
d600 = {s['app']: s for s in json.loads(args.d600.read_text())}
# An app's last result line is its result: the completion and retry passes append a new line for an app whose
# first try failed, and the scores come from that last try's logs.
last = {}
if args.results and args.results.exists():
    for line in args.results.read_text().splitlines():
        app, status, detail = (line.split('\t') + ['', ''])[:3]
        last[app] = (status, detail)
unlaunched = {app: status + ': ' + detail for app, (status, detail) in last.items() if status != 'launched'}


def rung(s):
    return RUNGS.index(s['rung_name'])


def blocker(s):
    return (s.get('blocker_category') or '-') + (': ' + s['blocker'][:110] if s.get('blocker') else '')


lines = []
both = sorted(set(phone) & set(d600))
lines.append('apps scored on both: %d (phone %d, D600 %d, not launched on the phone %d)'
             % (len(both), len(phone), len(d600), len(unlaunched)))
for name, side in (('phone', phone), ('D600', d600)):
    count = Counter(side[a]['rung_name'] for a in both)
    lines.append('%-6s %s' % (name, ', '.join('%s %d' % (r, count[r]) for r in reversed(RUNGS) if count[r])))
lower = [a for a in both if rung(phone[a]) < rung(d600[a])]
higher = [a for a in both if rung(phone[a]) > rung(d600[a])]
lines.append('phone lower: %d, phone higher: %d, same rung: %d' % (len(lower), len(higher),
                                                                  len(both) - len(lower) - len(higher)))
for title, apps in (('Phone lower than the D600', lower), ('Phone higher than the D600', higher)):
    lines.append('\n## ' + title)
    for a in sorted(apps, key=lambda a: (rung(phone[a]) - rung(d600[a]), a)):
        lines.append('%s  D600 %s -> phone %s\n    phone: %s\n    D600:  %s' % (
            a, d600[a]['rung_name'], phone[a]['rung_name'], blocker(phone[a]), blocker(d600[a])))
if unlaunched:
    lines.append('\n## Not launched on the phone')
    for a, why in sorted(unlaunched.items()):
        lines.append('%s  (D600 %s)  %s' % (a, d600[a]['rung_name'] if a in d600 else '-', why[:150]))
text = '\n'.join(lines) + '\n'
print(text)
if args.out:
    args.out.write_text(text)
