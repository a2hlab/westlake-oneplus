#!/system/bin/sh
# cam-verify-setup.sh: check camss_setup (the boot-time graph setup the OH camera patches install as
# /vendor/bin/camss_setup) against the IMX376K: reset the links, run it, show the result, capture 5 frames.
D=${CAM_DIR:-/data/local/tmp/cam}
MC=$D/media-ctl
M=$(for m in /dev/media*; do $MC -d $m -p 2>/dev/null | grep -q qcom-camss && echo $m; done | head -1)
[ -n "$M" ] || { echo "no qcom-camss media device"; exit 1; }
$MC -d $M -r
$D/yavta --no-query -w "0x009f0903 0" $($MC -d $M -e msm_csid0) >/dev/null   # CSID test pattern off
vid=$($D/camss_setup imx376 1 0 0 0) || { echo "camss_setup failed:"; dmesg | grep camss_setup | tail -3; exit 1; }
echo "camss_setup -> $vid"
for e in msm_csiphy1 msm_csid0 msm_vfe0_rdi0; do echo "$e: $($MC -d $M --get-v4l2 "\"$e\":0")"; done
$MC -d $M -p | grep -E -A6 'entity [0-9]+: msm_csid0 ' | grep -E 'ENABLED'
fmt=$($MC -d $M --get-v4l2 '"msm_vfe0_rdi0":0' | sed -n 's/.*fmt:\([A-Z0-9_]*\/[0-9]*x[0-9]*\).*/\1/p')
code=${fmt%%/*}; size=${fmt#*/}
pix=$(echo $code | sed 's/_1X10$/P/')
$D/yavta -B capture-mplane -n 4 -c5 -f $pix -s $size $vid 2>&1 | tail -6
