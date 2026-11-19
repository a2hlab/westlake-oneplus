#!/bin/bash
# host-camera-test.sh: run the camera bring-up test on the OnePlus 6 from the PC (after the RAM boot of
# boot-oneplus6-camera.img, see docs/camera.md). Every hdc call goes through scripts/config.sh (hdc_ = hdc -t
# <the phone>).
#   host-camera-test.sh push              copy modules, tools and phone scripts to /data/local/tmp/cam
#   host-camera-test.sh load [SENSOR]     load the modules (all sensors, or one), show dmesg + device nodes
#   host-camera-test.sh graph             print the media graph (media-ctl -p)
#   host-camera-test.sh capture SENSOR [FRAMES] [TESTPATTERN]
#                                         capture (tpg | imx376 | imx371 | imx519), pull the frames, make PNGs;
#                                         CAM_EXPOSURE=<lines> CAM_GAIN=<code> in the environment set the sensor
#   host-camera-test.sh dmesg             the camera part of the kernel log
#   host-camera-test.sh shell 'CMD'       run one command on the phone as root
set -euo pipefail
# CAMERA_TEST_DIR: the directory with the modules, tools and phone scripts (collect-test-files.sh makes it);
# REPO: a westlake-oneplus checkout whose scripts/config.sh (and local.sh) know hdc and the phone.
REPO=${REPO:-$(cd "$(dirname "$0")/.." && pwd)}
. "$REPO/scripts/config.sh"
A=${CAMERA_TEST_DIR:-$WORK_DIR/camera-test}
OUT=${OUT:-$A/results}
R=/data/local/tmp/cam
mkdir -p "$OUT"
sh_() { hdc_ shell "$*" | tr -d '\r'; }

case ${1:-} in
push)
	sh_ "mkdir -p $R/out"
	for f in qcom-camss.ko v4l2-cci.ko imx376.ko imx371.ko imx519.ko lc89821x.ko media-ctl yavta cam-load.sh cam-capture.sh; do
		hdc_ file send "$(tool_path "$HDC" "$A/$f")" "$R/$f" >/dev/null
	done
	sh_ "chmod 755 $R/media-ctl $R/yavta; cd $R && sha256sum *.ko media-ctl yavta cam-*.sh"
	echo "--- expected:"; (cd "$A" && sha256sum *.ko media-ctl yavta cam-*.sh)
	;;
load)    sh_ "cd $R && sh cam-load.sh ${2:-}" ;;
graph)   sh_ "$R/media-ctl -d \$(for m in /dev/media*; do $R/media-ctl -d \$m -p 2>/dev/null | grep -q qcom-camss && echo \$m; done | head -1) -p" ;;
dmesg)   sh_ "dmesg | grep -i -E 'camss|cci|imx|lc898|csiphy|csid|vfe|smmu|gdsc' | tail -80" ;;
shell)   shift; sh_ "$*" ;;
capture)
	s=${2:?sensor}
	sh_ "cd $R && CAM_EXPOSURE=${CAM_EXPOSURE:-} CAM_GAIN=${CAM_GAIN:-} sh cam-capture.sh $s ${3:-10} ${4:-0}"
	d="$OUT/$s-$(date +%H%M%S)"; mkdir -p "$d"
	for f in $(sh_ "ls $R/out/ | grep -E '^$s(-[0-9]+\\.raw|\\.txt)\$'"); do
		hdc_ file recv "$R/out/$f" "$(tool_path "$HDC" "$d")/$f" >/dev/null
	done
	ls -l "$d"
	for f in "$d"/*.raw; do [ -e "$f" ] && python3 -I "$(dirname "$0")/raw2png.py" "$f" --info "$d/$s.txt"; done
	echo "PNGs in $d"
	;;
*) sed -n '2,12p' "$0"; exit 2 ;;
esac
