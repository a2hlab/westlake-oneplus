#!/bin/bash
# Check that every project of the tree is at the commit the tested build used (manifests/oh61-full-pinned.xml).
set -euo pipefail
. "$(dirname "$0")/config.sh"
export PATH="$HOST_DIR/bin:$PATH"
cd "$OH_ROOT"
cur=$(mktemp); trap 'rm -f "$cur"' EXIT
repo manifest -r -o "$cur" >/dev/null 2>&1
python3 - "$REPO_DIR/manifests/oh61-full-pinned.xml" "$cur" <<'EOF'
import sys, xml.etree.ElementTree as ET
def pins(p):
    return {e.get('path') or e.get('name'): e.get('revision') for e in ET.parse(p).getroot().iter('project')}
want, have = pins(sys.argv[1]), pins(sys.argv[2])
missing = sorted(set(want) - set(have)); extra = sorted(set(have) - set(want))
diff = sorted(p for p in set(want) & set(have) if want[p] != have[p])
for p in missing: print('MISSING ', p)
for p in extra:   print('EXTRA   ', p)
for p in diff:    print('DIFFERENT', p, have[p], '!=', want[p])
print(f'{len(want)} pinned projects: {len(missing)} missing, {len(extra)} extra, {len(diff)} at other commits')
sys.exit(1 if (missing or diff) else 0)
EOF
