#!/usr/bin/env python3
"""round_score.py LOGS_DIR [--before D600_LOGS_DIR] [--json OUT]: score a round of 07-round.sh with the harness's
lifecycle scorer (westlake_gap.lifecycle; WL_HARNESS: the westlake-harness checkout), changed in two ways:

- the host screens are SceneBoard's (refs/, see round_screen.py), not the D600 launcher host's pages;
- a managed launch binds the app through OH's ScheduleLaunchApplication, and its log says "[B43-BIND]
  handleBindApplication returned OK" where a direct launch says sBindAppDone=true.

--before: a D600 round's logs (run_apps.sh), scored as the harness scores them, compared app by app with this one
(only the apps of this round)."""
import argparse
import json
import os
import re
import sys
from collections import Counter
from pathlib import Path

sys.path.insert(0, os.environ['WL_HARNESS'])
from harness.westlake_gap import lifecycle  # noqa: E402

sys.path.insert(0, str(Path(__file__).resolve().parent))
from round_screen import refs  # noqa: E402

MANAGED_BIND = r'\[B43-BIND\] handleBindApplication returned OK'

parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
parser.add_argument('logs', type=Path)
parser.add_argument('--before', type=Path)
parser.add_argument('--json', type=Path)
args = parser.parse_args()

files = sorted(args.logs.glob('*.stderr'))
if not files:
    parser.error('no .stderr files in ' + str(args.logs))
before = None
if args.before:
    names = {f.name for f in files}
    before = lifecycle.score_paths(sorted(f for f in args.before.glob('*.stderr') if f.name in names))

lifecycle._HOST_SCREENS = refs()
pattern, needed = lifecycle._MARKERS['bound']
lifecycle._MARKERS['bound'] = (re.compile(pattern.pattern + '|' + MANAGED_BIND), needed)
lifecycle._PROGRESS = re.compile(lifecycle._PROGRESS.pattern + '|' + MANAGED_BIND)
scores = lifecycle.score_paths(files)
print(lifecycle.table(scores))
print()
print('rungs:', ', '.join('%s %d' % kv for kv in sorted(Counter(s.rung_name for s in scores).items(),
                                                       key=lambda kv: -lifecycle.RUNGS.index(kv[0]))),
      'of', len(scores))
if before is not None:
    print()
    print(lifecycle.compare(before, scores))
    was = Counter(s.rung_name for s in before)
    print('\nD600 rungs for these apps:', ', '.join('%s %d' % kv for kv in sorted(
        was.items(), key=lambda kv: -lifecycle.RUNGS.index(kv[0]))), 'of', len(before))
if args.json:
    args.json.write_text(json.dumps([s.as_dict() for s in scores], indent=1) + '\n')
