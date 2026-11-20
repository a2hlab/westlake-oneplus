#!/system/bin/sh
# cam-capture.sh: configure the CAMSS media graph for one camera and capture raw Bayer frames with yavta.
#   sh cam-capture.sh SENSOR [FRAMES] [TESTPATTERN]
#     SENSOR       imx376 (rear secondary, CSIPHY1) | imx371 (front, CSIPHY2) | imx519 (rear main, CSIPHY0, C-PHY)
#                  | tpg (no sensor: the CSID's own test pattern generator, 2592x1940 SRGGB10)
#     FRAMES       frames to capture (default 10; the last 3 are written to files)
#     TESTPATTERN  sensor test pattern index (0 = off = real image; imx376/imx371: 1 solid colour,
#                  2 colour bars, 3 fade to grey, 4 PN9; imx519: 1 colour bars, 2 solid colour,
#                  3 grey bars, 4 PN9; tpg: 1-9, default 9 = colour bars)
# Output: $CAM_DIR/out/<sensor>-<n>.raw (+ .txt with format, size, stride for the raw2png.py converter)
D=${CAM_DIR:-/data/local/tmp/cam}
MC=$D/media-ctl
YAVTA=$D/yavta
sensor=${1:?usage: cam-capture.sh imx376|imx371|imx519|tpg [frames] [testpattern]}
frames=${2:-10}
tp=${3:-0}
mkdir -p $D/out

case $sensor in
	imx519) phy=0 ;;
	imx376) phy=1 ;;
	imx371) phy=2 ;;
	tpg) phy= ;;
	*) echo "unknown sensor $sensor"; exit 2 ;;
esac

# the CAMSS media device
M=
for m in /dev/media*; do
	if $MC -d $m -p 2>/dev/null | grep -q 'qcom-camss'; then M=$m; break; fi
done
[ -n "$M" ] || { echo "no qcom-camss media device (run cam-load.sh)"; exit 1; }
echo "media device $M"

$MC -d $M -r || exit 1
if [ $sensor = tpg ]; then
	fmt=SRGGB10_1X10/2592x1940
	$MC -d $M -l '"msm_csid0":1->"msm_vfe0_rdi0":0[1]' || exit 1
	$MC -d $M -V "\"msm_csid0\":0[fmt:$fmt field:none],\"msm_vfe0_rdi0\":0[fmt:$fmt field:none]" || exit 1
	sd=$($MC -d $M -e msm_csid0)
	[ "$tp" = 0 ] && tp=9
	# CSID test pattern generator (V4L2_CID_TEST_PATTERN on the CSID subdev)
	$YAVTA --no-query -w "0x009f0903 $tp" $sd
else
	ent=$($MC -d $M -p | sed -n "s/^- entity [0-9]*: \($sensor[0-9a-z]* [0-9]*-[0-9a-f]*\) .*/\1/p" | head -1)
	[ -n "$ent" ] || { echo "sensor $sensor not in the media graph (module loaded? probe ok? see dmesg)"; exit 1; }
	echo "sensor entity \"$ent\" on msm_csiphy$phy"
	fmt=$($MC -d $M --get-v4l2 "\"$ent\":0" | sed -n 's/.*fmt:\([A-Z0-9_]*\/[0-9]*x[0-9]*\).*/\1/p')
	[ -n "$fmt" ] || { echo "cannot read the sensor format"; exit 1; }
	# the CSID refuses a CSIPHY link while its test pattern generator is on (step "tpg" leaves it on)
	$YAVTA --no-query -w "0x009f0903 0" $($MC -d $M -e msm_csid0) >/dev/null
	$MC -d $M -l "\"msm_csiphy$phy\":1->\"msm_csid0\":0[1],\"msm_csid0\":1->\"msm_vfe0_rdi0\":0[1]" || exit 1
	$MC -d $M -V "\"$ent\":0[fmt:$fmt field:none],\"msm_csiphy$phy\":0[fmt:$fmt field:none],\"msm_csid0\":0[fmt:$fmt field:none],\"msm_vfe0_rdi0\":0[fmt:$fmt field:none]" || exit 1
	sd=$($MC -d $M -e "$ent")
	$YAVTA --no-query -w "0x009f0903 $tp" $sd
	# exposure / gain can be set the same way: 0x00980911 exposure (lines), 0x009e0903 analogue gain
	[ -n "$CAM_EXPOSURE" ] && $YAVTA --no-query -w "0x00980911 $CAM_EXPOSURE" $sd
	[ -n "$CAM_GAIN" ] && $YAVTA --no-query -w "0x009e0903 $CAM_GAIN" $sd
fi
echo "format $fmt"
$MC -d $M -p | grep -E -A3 "entity [0-9]+: (msm_csiphy$phy|msm_csid0|msm_vfe0_rdi0|$sensor)" | grep -E 'entity|fmt:|ENABLED' | head -20

code=${fmt%%/*}; size=${fmt#*/}
pix=$(echo $code | sed 's/_1X10$/P/; s/_1X8$//; s/_1X12$/P/')
vid=$($MC -d $M -e msm_vfe0_video0)
echo "capturing $frames frames, $pix $size, from $vid"
skip=$((frames - 3)); [ $skip -lt 0 ] && skip=0
rm -f $D/out/$sensor-*.raw
$YAVTA -B capture-mplane -n 4 -c$frames --skip $skip -f $pix -s $size -F$D/out/$sensor-#.raw $vid 2>&1 | tail -15
w=${size%x*}
bpl=$(( (w * 10 / 8 + 15) / 16 * 16 ))
echo "pixfmt=$pix width=$w height=${size#*x} bytesperline=$bpl" > $D/out/$sensor.txt
ls -l $D/out/
