#!/bin/bash
# Check a running OH over hdc: version, kernel, boot completion, installed apps, UI processes, and save a
# screenshot to $WORK_DIR. Waits up to 3 minutes for bootevent.boot.completed.
set -euo pipefail
. "$(dirname "$0")/config.sh"
"$HDC" list targets </dev/null 2>/dev/null | grep -q "$HDC_TARGET" || die "no hdc target $HDC_TARGET"
sh_() { hdc_ shell "$@" | tr -d '\r'; }
for _ in $(seq 1 90); do
  [ "$(sh_ param get bootevent.boot.completed 2>/dev/null | tr -d ' ')" = true ] && break; sleep 2
done
echo "version:        $(sh_ param get const.ohos.fullname)"
echo "kernel:         $(sh_ uname -r)"
echo "boot completed: $(sh_ param get bootevent.boot.completed)"
echo "apps installed: $(sh_ 'ls /data/app/el1/bundle/public 2>/dev/null | wc -l')"
echo "UI processes:   $(sh_ 'ps -ef' | grep -oE 'com\.ohos\.(launcher|systemui|sceneboard)[^ ]*' | sort -u | tr '\n' ' ')"
echo "uptime:         $(sh_ 'cut -d" " -f1 /proc/uptime') s"
shot="$WORK_DIR/screenshot-$(date +%Y%m%d-%H%M%S).jpeg"
sh_ "snapshot_display -f /data/local/tmp/check.jpeg" >/dev/null
hdc_ file recv /data/local/tmp/check.jpeg "$(tool_path "$HDC" "$(dirname "$shot")")/$(basename "$shot")" >/dev/null
[ -s "$shot" ] && echo "screenshot:     $shot"
