#!/bin/bash
# Prepare the phone for Westlake. Run after EVERY boot of OH (/data is a RAM disk: everything below is gone
# at the next boot; the phone's partitions are not touched):
#   - the Westlake device tools call sha256sum and chcon, which this build's toybox lacks: a copy of
#     /system/bin with an openssl-based sha256sum and a no-op chcon (SELinux is disabled here) is
#     bind-mounted over /system/bin
#   - installs the Westlake host HAP ($WL_HOST)
set -euo pipefail
. "$(dirname "$0")/config.sh"
wl_need WL_HOST_HAP
t=$WL_DIR/tools

step "sha256sum and chcon"
if wl_hdc shell 'sha256sum /system/bin/sh' | tr -d '\r' | grep -qE '^[0-9a-f]{64}  /system/bin/sh$'; then
  echo "  already in place"
else
  wl_hdc file send "$(wl_tool_path "$t/sha256sum.sh")" /data/local/tmp/wl-sha256sum >/dev/null
  wl_hdc file send "$(wl_tool_path "$t/chcon.sh")" /data/local/tmp/wl-chcon >/dev/null
  wl_hdc shell 'O=/data/local/tmp/wl-sysbin; rm -rf $O && cp -a /system/bin $O &&
    rm -f $O/sha256sum $O/chcon && cp /data/local/tmp/wl-sha256sum $O/sha256sum && cp /data/local/tmp/wl-chcon $O/chcon &&
    chmod 755 $O/sha256sum $O/chcon && [ "$(ls $O | wc -l)" = "$(ls /system/bin | wc -l)" ] &&
    mount --bind $O /system/bin && echo "  bind mount OK"' | tr -d '\r'
  wl_hdc shell 'sha256sum /system/bin/sh' | tr -d '\r' | grep -qE '^[0-9a-f]{64}  /system/bin/sh$' \
    || die "sha256sum still missing on the phone"
fi

step "host HAP $WL_HOST"
hap=$(wl_build "$WL_HOST_HAP"); [ -f "$hap" ] || die "$hap missing"
if wl_hdc shell "bm dump -n $WL_HOST" | grep -q '"bundleName"'; then
  echo "  already installed"
else
  (cd "$(dirname "$hap")" && wl_hdc install "$(basename "$hap")") | tr -d '\r' | tail -1
  wl_hdc shell "bm dump -n $WL_HOST" | grep -q '"bundleName"' || die "host HAP did not install"
fi
