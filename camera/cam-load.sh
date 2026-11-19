#!/system/bin/sh
# cam-load.sh: load the camera modules on the OnePlus 6 (OH 7.0, 5.10.194-sdm845 kernel, camera DTB booted).
# Run as root from the directory that holds the new .ko files (default /data/local/tmp/cam).
#   sh cam-load.sh            all sensors
#   sh cam-load.sh imx376     CAMSS + this sensor only (imx371 | imx376 | imx519)
D=${CAM_DIR:-/data/local/tmp/cam}
SYS=/system/lib/modules/$(uname -r)/kernel
only=$1

ins() {  # ins FILE: insmod, quiet if already loaded
	n=$(basename "$1" .ko | sed 's/-/_/g')
	if grep -q "^$n " /proc/modules; then echo "  loaded   $n"; return 0; fi
	if insmod "$1"; then echo "  insmod   $n"; else echo "  FAILED   $n ($1)"; return 1; fi
}

echo "kernel $(uname -r), camss in DT: $(ls -d /sys/firmware/devicetree/base/soc@0/camss@acb3000 2>/dev/null || echo NO)"
echo "== modules from the system image"
ins $SYS/drivers/media/v4l2-core/v4l2-fwnode.ko
ins $SYS/drivers/media/common/videobuf2/videobuf2-common.ko
ins $SYS/drivers/media/common/videobuf2/videobuf2-v4l2.ko
ins $SYS/drivers/media/common/videobuf2/videobuf2-memops.ko
ins $SYS/drivers/media/common/videobuf2/videobuf2-dma-sg.ko
grep -q '^camcc_sdm845 ' /proc/modules || ins $SYS/drivers/clk/qcom/camcc-sdm845.ko
echo "== new modules from $D"
ins $D/v4l2-cci.ko
ins $D/qcom-camss.ko || exit 1
sleep 1
for s in imx376 imx371 imx519; do
	[ -n "$only" ] && [ "$only" != "$s" ] && continue
	ins $D/$s.ko
done
[ -z "$only" ] && ins $D/lc89821x.ko
sleep 2
echo "== kernel log (camss, cci, sensors)"
dmesg | grep -i -E 'camss|cci|imx3|imx5|lc898|csiphy|csid|vfe|qcom-camss' | tail -40
echo "== device nodes"
ls -l /dev/media* /dev/v4l-subdev* 2>/dev/null
for v in /sys/class/video4linux/video*; do echo "  $(basename $v): $(cat $v/name)"; done
