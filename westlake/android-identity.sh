#!/bin/bash
# android-identity.sh: give the phone's Android identity to Westlake's apps: a OnePlus 6, the phone's own hardware.
#
# Westlake's Build.* and native property reads (the runtime's SystemProperties and the bionic shim's table) ask OH's
# parameter store first, under the Android name, and fall back to a built-in table only when OH has no such parameter.
# That table is the D600 board's identity (HopeRun DAYU200); before 2026-11-21 it was "OpenHarmony/rk3568". OH 7.0 on
# the phone has its own names (const.product.manufacturer=Oneplus, const.product.model=Fajita) but none of the Android
# ones, so this sets them: brand, manufacturer, model, device and product as on the phone's stock software (OxygenOS,
# vendor build.prop: OnePlus, ONEPLUS A6003, OnePlus6), the SoC as Android reports it on this phone, and build fields
# for the Android version Westlake runs (14, API 34; the phone's stock software is Android 10 or 11, which apps would
# then see contradict SDK_INT). Google's check-in restricted a board whose fingerprint said OpenHarmony
# (uncertified_status 3); the D600 checked in as an Android device and got 1.
#
# OH keeps ro.* parameters read-only once set and does not keep them across a boot: run after every boot (03-prep.sh
# does) and before any app starts. A parameter OH already has keeps its value (reported). WL_ANDROID_MODEL changes the
# model (both phones of this setup report ONEPLUS A6003 in their stock vendor build.prop).
set -uo pipefail
[ -n "${WL_ENV:-}" ] && { set -a; . "$WL_ENV"; set +a; }
. "$(dirname "$0")/config.sh"
model=${WL_ANDROID_MODEL:-ONEPLUS A6003}
build_id=UP1A.231005.007; incremental=eng.20261121
props=(
  "ro.product.brand=OnePlus"
  "ro.product.manufacturer=OnePlus"
  "ro.product.model=$model"
  "ro.product.device=OnePlus6"
  "ro.product.name=OnePlus6"
  "ro.product.board=sdm845"
  "ro.hardware=qcom"
  "ro.boot.hardware=qcom"
  "ro.board.platform=sdm845"
  "ro.soc.manufacturer=QTI"
  "ro.soc.model=SDM845"
  "ro.build.id=$build_id"
  "ro.build.display.id=$build_id"
  "ro.build.version.incremental=$incremental"
  "ro.build.user=oneplus"
  "ro.build.host=oneplus"
  "ro.build.fingerprint=OnePlus/OnePlus6/OnePlus6:14/$build_id/$incremental:user/release-keys"
)
step "Android identity: $model (OnePlus 6)"
# One hdc call per parameter (a few seconds in all), so a long value never meets the shell command's length limit.
for p in "${props[@]}"; do
  k=${p%%=*}; v=${p#*=}
  wl_hdc shell "cur=\$(param get '$k' 2>&1 | head -1); cur=\${cur%% };
    case \"\$cur\" in
      *fail*) if param set '$k' '$v' >/dev/null 2>&1; then echo '  $k=$v'; else echo '  $k: could not be set'; fi ;;
      '$v') echo '  $k: already $v' ;;
      *) echo \"  $k: OH has \$cur (kept)\" ;;
    esac" | tr -d '\r'
done
