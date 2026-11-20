#!/bin/bash
# winexe-retry.sh TOOL.exe ARGS...: run a Windows tool from WSL, and run it again when WSL could not start it.
# Long-lived WSL sessions lose interop sockets ("UtilAcceptVsock ... accept4 failed 110"): the tool never ran, so
# stdin is untouched and repeating the call is safe. stdout goes through a file (binary-safe, e.g. adb exec-out),
# stderr is passed on; notices go to WINEXE_RETRY_LOG.
# For adb or fastboot, a wrapper whose name ends in .exe keeps config.sh's Windows path handling, e.g. adb.exe:
#   #!/bin/bash
#   exec /path/to/scripts/winexe-retry.sh /mnt/c/path/to/platform-tools/adb.exe "$@"
# with ADB=/path/to/that/adb.exe in scripts/local.sh (westlake/tools/hdc-retry.sh does the same for hdc).
exe=${1:?usage: $0 TOOL.exe ARGS...}; shift
LOG=${WINEXE_RETRY_LOG:-${XDG_RUNTIME_DIR:-/tmp}/winexe-retry.log}
tmp=$(mktemp) || exit 1
trap 'rm -f "$tmp"' EXIT
for attempt in 1 2 3 4 5 6 7 8; do
  err=$("$exe" "$@" 2>&1 >"$tmp"); rc=$?
  if printf '%s' "$err" | grep -q "UtilAcceptVsock"; then
    echo "$(date +%T) $(basename "$exe") $1: interop failed (attempt $attempt), again" >> "$LOG"
    sleep 1; continue
  fi
  cat "$tmp"; [ -n "$err" ] && printf '%s\n' "$err" >&2
  exit $rc
done
cat "$tmp"; printf '%s\n' "$err" >&2; exit 1
