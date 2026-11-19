#!/usr/bin/env python3
"""round_signals.py LOGS_DIR [--app PACKAGE]: what OpenHarmony 7.0 and the managed launch did to each app of a round
(07-round.sh), beside what the harness's scorer reads. Per app, from its log (.stderr) and hilog:

  clean      OH sent ScheduleCleanAbility: it ended the app's ability (a timeout, or the app's own finish)
  rc22       OH refused the app's first FOREGROUND report (rc 22: too late, or before OH asked; shown only when the
             bridge's deadline did not report it first)
  deadline   the bridge reported FOREGROUND because the app had not, 3.5 s after OH asked
  appfg      the bridge sent ApplicationForegrounded because the app's main looper was busy
  held       an activity window held back, waiting for the OH ability's main window
  waiting    an ability transaction still waited for its activity launch after 60 s
  handoff    the OH ability passed from a finishing activity to the next (splash, finish, finishAffinity)
  secure     a window set FLAG_SECURE

Prints one line per app with the signals it had, then how many apps had each."""
import argparse
import re
from collections import Counter
from pathlib import Path

SIGNALS = {
    'clean': ('hilog', re.compile(r'ScheduleCleanAbility')),
    'rc22': ('hilog', re.compile(r'activityResumed \(first-frame(?: timeout)?\): OH AbilityTransitionDone\(.*rc=22')),
    'deadline': ('stderr', re.compile(r'the bridge reported it')),
    'appfg': ('stderr', re.compile(r'the bridge sent ApplicationForegrounded')),
    'held': ('stderr', re.compile(r"\[OH_WSA\] holding back type=1 .* until the OH ability's main window")),
    'waiting': ('stderr', re.compile(r'its activity launch still runs after 60 s')),
    'handoff': ('stderr', re.compile(r'\[WL-MANAGED\] the OH ability (went with|stays with)')),
    'secure': ('stderr', re.compile(r'FLAG_SECURE=true')),
}

parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
parser.add_argument('logs', type=Path)
parser.add_argument('--app')
args = parser.parse_args()

results = {}
results_file = args.logs / 'results.tsv'
if results_file.exists():
    for line in results_file.read_text().splitlines():
        app, status, detail = (line.split('\t') + ['', ''])[:3]
        results[app] = (status, detail)

totals = Counter()
for stderr in sorted(args.logs.glob('*.stderr')):
    app = stderr.stem
    if args.app and app != 'hk-' + args.app and app != args.app:
        continue
    texts = {'stderr': stderr.read_text(errors='replace')}
    hilog = stderr.with_suffix('.hilog')
    texts['hilog'] = hilog.read_text(errors='replace') if hilog.exists() else ''
    had = [name for name, (where, pattern) in SIGNALS.items() if pattern.search(texts[where])]
    if 'deadline' in had and 'rc22' in had:
        had.remove('rc22')   # the app's own report came after the bridge's: OH had it already
    totals.update(had)
    status, detail = results.get(app, ('?', ''))
    left = re.search(r'(on screen after \d+s|gone after \d+s|waited \d+s|stopped: [^ ]+)', detail)
    print('%-58s %-22s %s' % (app[:58], left.group(1) if left else status, ' '.join(had)))
print()
print('apps:', len(list(args.logs.glob('*.stderr'))), '|', ', '.join('%s %d' % kv for kv in totals.most_common()))
