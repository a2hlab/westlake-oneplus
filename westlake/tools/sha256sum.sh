#!/bin/sh
# sha256sum for the Westlake device tools on the OnePlus 6 build: its toybox has no sha256sum applet,
# openssl computes the same digest. Output format and missing-file behaviour as coreutils.
rc=0
for f in "$@"; do
  if h=$(openssl dgst -sha256 -r "$f" 2>/dev/null) && [ -n "$h" ]; then
    echo "${h%% *}  $f"
  else
    echo "sha256sum: $f: No such file or directory" >&2; rc=1
  fi
done
exit $rc
