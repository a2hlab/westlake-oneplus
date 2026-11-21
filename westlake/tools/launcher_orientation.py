#!/usr/bin/env python3
"""launcher_orientation.py: an app's launcher activity's android:screenOrientation, for its managed bundle.

  launcher_orientation.py --download APK_OR_XAPK --activity CLASS   the number, or nothing when it has none
  launcher_orientation.py --corpus DL_DIR MAP_DIR                   package, activity, number ("-": none) per
                                                                    download, the activity from its scan.json

The managed launch (make_managed_bundle.py --orientation) gives the app's OH ability this orientation, so
SceneBoard turns the screen before it makes the app's window. Without it a landscape game drew its landscape
layout into a portrait window. The manifest is read from the base APK in memory (an XAPK's base is the APK
named after the package, or else its largest APK that is not a config split); nothing is unpacked. An
activity-alias takes its target's orientation, as Android does. Needs Androguard, as the harness's scanner does.
"""
import argparse
import io
import json
import sys
import zipfile
from pathlib import Path

from loguru import logger

logger.remove()  # Androguard logs every resource it parses
from androguard.core.axml import AXMLPrinter  # noqa: E402

NS = '{http://schemas.android.com/apk/res/android}'


def manifest_of(download):
    """The base APK's binary AndroidManifest.xml, from an APK or an XAPK."""
    with zipfile.ZipFile(download) as outer:
        names = outer.namelist()
        if 'AndroidManifest.xml' in names:
            return outer.read('AndroidManifest.xml')
        package = Path(download).name.split('@')[0]
        apks = [n for n in names if n.endswith('.apk') and '/' not in n and not n.startswith('config.')]
        if not apks:
            raise ValueError('no base APK in ' + str(download))
        base = next((n for n in apks if n in (package + '.apk', 'base.apk')), None) or \
            max(apks, key=lambda n: outer.getinfo(n).file_size)
        with outer.open(base) as member:
            # A stored member is read in place; a compressed one must be inflated to be seekable.
            inner = zipfile.ZipFile(member if outer.getinfo(base).compress_type == zipfile.ZIP_STORED
                                    else io.BytesIO(member.read()))
            return inner.read('AndroidManifest.xml')


def orientation(download, activity):
    """The activity's android:screenOrientation as Android's number, or None."""
    xml = AXMLPrinter(manifest_of(download)).get_xml_obj()
    package = xml.get('package') or ''

    def full(name):
        return package + name if name.startswith('.') else (name if '.' in name else package + '.' + name)

    activity = full(activity)
    activities = {full(e.get(NS + 'name') or ''): e for e in xml.iter('activity')}
    element = activities.get(activity)
    if element is None:
        for alias in xml.iter('activity-alias'):
            if full(alias.get(NS + 'name') or '') == activity:
                element = activities.get(full(alias.get(NS + 'targetActivity') or ''))
                break
    value = element.get(NS + 'screenOrientation') if element is not None else None
    return int(value) if value not in (None, '') else None


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--download', type=Path, help='an APK or XAPK')
    parser.add_argument('--activity', help='the launcher activity class')
    parser.add_argument('--corpus', nargs=2, type=Path, metavar=('DL_DIR', 'MAP_DIR'))
    args = parser.parse_args()
    if args.corpus:
        dl, maps = args.corpus
        for download in sorted(dl.iterdir()):
            package = download.name.split('@')[0]
            try:
                activity = json.loads((maps / package / 'scan.json').read_text())['apk']['main_activities'][0]
                value = orientation(download, activity)
            except Exception as e:  # one download must not stop the table
                print(package, '-', '-', 'error: ' + type(e).__name__, sep='\t')
                continue
            print(package, activity, '-' if value is None else value, sep='\t')
        return
    if not (args.download and args.activity):
        parser.error('--download and --activity, or --corpus')
    value = orientation(args.download, args.activity)
    if value is not None:
        print(value)


if __name__ == '__main__':
    sys.exit(main())
