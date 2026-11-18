#!/bin/bash
# hdc for the Westlake probes when hdc is the Windows hdc.exe called from WSL. Long-lived WSL shells lose
# interop sockets ("UtilAcceptVsock ... accept4 failed 110"); the Windows side never ran then, so the call is
# repeated on a socket that answers. Notices go to a log file only: the probes parse the combined output.
# Set HDC_EXE to hdc.exe (a /mnt/... path). Keeps the working directory (hdc file send takes relative names).
# westlake-harness device/hdc_wsl.sh picks one proven socket and runs hdc once; on this machine a socket that
# just passed such a check still failed the next call (2026-11-18), so the call itself is checked and repeated.
: "${HDC_EXE:?set HDC_EXE to the Windows hdc.exe}"
LOG=${HDC_RETRY_LOG:-${XDG_RUNTIME_DIR:-/tmp}/hdc-retry.log}
CACHE=${XDG_RUNTIME_DIR:-/tmp}/hdc-retry-interop
ok() { [ -S "$1" ] && (cd / && WSL_INTEROP=$1 timeout 3 cmd.exe /c exit 0 </dev/null >/dev/null 2>&1); }
pick() {  # pick [skip]: first socket that answers, other than skip
  for c in ${WSL_INTEROP:-} $(ls -t /run/WSL/*_interop 2>/dev/null); do
    [ "$c" = "${1:-}" ] && continue
    if ok "$c"; then echo "$c" > "$CACHE"; echo "$c"; return 0; fi
  done
  return 1
}
s=$(cat "$CACHE" 2>/dev/null); [ -S "$s" ] || s=$(pick)
for attempt in 1 2 3 4 5; do
  out=$(WSL_INTEROP=$s "$HDC_EXE" "$@" 2>&1); rc=$?
  if printf '%s' "$out" | grep -q "UtilAcceptVsock"; then
    echo "$(date +%T) interop $s failed (attempt $attempt): switching" >> "$LOG"
    s=$(pick "$s") || { sleep 1; s=$(pick); }
    continue
  fi
  printf '%s\n' "$out"; exit $rc
done
printf '%s\n' "$out"; exit 1
