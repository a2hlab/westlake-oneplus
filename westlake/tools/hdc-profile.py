#!/usr/bin/env python3
"""hdc-profile.py TIMING_LOG ROUND_LOG: where each app's turn in a corpus round goes.

TIMING_LOG is tools/hdc-retry.sh's timing log ("<start> <end> <exit code> <arguments>" per hdc call, written while
the file HDC_TIMING_FLAG exists); ROUND_LOG is 07-round.sh's round-TAG.log ("<date> <time> <app> launched ...
turn=<N>s"). For each launched app: the turn's length, its hdc calls and their time by kind (shell, file send, file
recv), the time between calls (host-side work and waits), and its longest calls and gaps. The round log has the
host's local time: run this in the same time zone as the round."""
import datetime
import re
import sys

if len(sys.argv) != 3:
    sys.exit(__doc__.split('\n\n')[0])

calls = []
for line in open(sys.argv[1], errors='replace'):
    parts = line.rstrip('\n').split(' ', 3)
    if len(parts) < 4:
        continue
    try:
        calls.append((float(parts[0]), float(parts[1]), parts[2], parts[3]))
    except ValueError:
        continue
calls.sort()

turns = []
for line in open(sys.argv[2], errors='replace'):
    m = re.match(r'(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d) (\S+) launched .* turn=(\d+)s', line)
    if m:
        end = datetime.datetime.strptime(m.group(1), '%Y-%m-%d %H:%M:%S').timestamp()
        turns.append((m.group(2), end - int(m.group(3)), end))


def kind(args):
    a = args.split()
    for i, w in enumerate(a):
        if w in ('shell', 'file'):
            return ('file ' + a[i + 1]) if w == 'file' and i + 1 < len(a) else 'shell'
    return 'other'


for app, start, end in turns:
    mine = [c for c in calls if start - 1 <= c[0] <= end + 1]
    if not mine:
        continue
    by = {}
    gaps = []
    prev_end = start
    for s, e, rc, args in mine:
        k = kind(args)
        by[k] = by.get(k, 0) + (e - s)
        gaps.append((s - prev_end, args))
        prev_end = max(prev_end, e)
    gaps.append((end - prev_end, '(end of turn)'))
    total_calls = sum(e - s for s, e, _, _ in mine)
    host = sum(g for g, _ in gaps if g > 0)
    print('%s: turn %.0f s, %d hdc calls %.1f s (%s), host-side/waits between calls %.1f s' % (
        app, end - start, len(mine), total_calls,
        ', '.join('%s %.1f' % (k, v) for k, v in sorted(by.items(), key=lambda x: -x[1])), host))
    for s, e, rc, args in sorted(mine, key=lambda c: c[0] - c[1])[:4]:
        print('    call %5.1f s  %s' % (e - s, args[:110]))
    for g, args in sorted(gaps, key=lambda x: -x[0])[:4]:
        print('    gap  %5.1f s  before: %s' % (g, args[:100]))
