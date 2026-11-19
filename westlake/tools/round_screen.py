#!/usr/bin/env python3
"""round_screen.py SCREENSHOT: 'app' when a screenshot of the phone shows an app rather than what SceneBoard shows
without one, else 'host' (that screen) or 'partial' (that screen with something over part of it).

What SceneBoard shows without an app is its desktop, or the plain white starting window of an app that has not
drawn yet; westlake/refs/host-screen-*.png are those screens as the harness's host-screen check compares them
(westlake_gap.lifecycle.screen_state, which 07-round.sh's early exit and tools/round_score.py both use).
WL_HARNESS: the westlake-harness checkout.

round_screen.py --make-ref NAME SCREENSHOT: write refs/host-screen-NAME.png from a screenshot of such a screen."""
import os
import sys
from pathlib import Path

sys.path.insert(0, os.environ['WL_HARNESS'])
from harness.westlake_gap import lifecycle  # noqa: E402

REFS = Path(__file__).resolve().parents[1] / 'refs'


def refs():
    return sorted(REFS.glob('host-screen-*.png'))


if __name__ == '__main__':
    if sys.argv[1] == '--make-ref':
        from PIL import Image
        page = Image.new('L', (60, 88))
        page.putdata(lifecycle._thumbnail(Path(sys.argv[3])))   # the check's own crop and scale
        page.save(REFS / f'host-screen-{sys.argv[2]}.png')
    else:
        print(lifecycle.screen_state(Path(sys.argv[1]), refs()) or 'unknown')
