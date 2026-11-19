# Cameras (OH 7.0 branch): kernel bring-up and on-phone test

Status: the kernel side is written and built, **not yet run on a phone**. This page says what the patches
do and how to test them without flashing anything.

## The hardware

| | rear main | rear secondary | front |
|---|---|---|---|
| sensor | Sony IMX519 16 MP | Sony IMX376K 20 MP | Sony IMX371 16 MP |
| CSI-2 into CAMSS | CSIPHY0, **MIPI C-PHY**, 3 trios | CSIPHY1, D-PHY, 4 lanes | CSIPHY2, D-PHY, 4 lanes |
| control | CCI0 0x1a (lens LC898217XC 0x72) | CCI1 0x10 (lens 0x74) | CCI0 0x10 |
| clock, reset | MCLK0 (GPIO13), GPIO28 | MCLK2 (GPIO15), GPIO23 | MCLK1 (GPIO14), GPIO9 |

All three deliver raw Bayer (RAW10). SDM845's camera subsystem (CAMSS) in Linux has no ISP: frames go
CSIPHY -> CSID -> VFE "RDI" -> memory unchanged; demosaicing and exposure/white balance are software.

## Where the drivers come from

The [sdm845-mainline](https://codeberg.org/sdm845/linux) tree (branch `sdm845-next`) runs all three cameras
on mainline Linux: the D-PHY ones since early 2025, the IMX519 with a CAMSS C-PHY extension (in review
upstream). The port's 5.10 kernel has CAMSS only for older SoCs (VFE 4.1/4.7) and no camera nodes, so the
phone had no camera. The patches backport that tree:

- `patches/kernel/0005`: CAMSS for SDM845 (CSIPHY incl. C-PHY, CSID gen2, VFE 17x, video nodes), reduced
  to SDM845 and ported to the 5.10 media core (`camss-compat.h`); each sensor is linked as soon as it
  binds, so one sensor failing does not hide the others.
- `patches/kernel/0006`: the IMX519, IMX376K and IMX371 drivers, the lens driver (`lc89821x`), and the
  `v4l2-cci` register helpers (5.10 lacks them).
- `patches/kernel/0007`: `sdm845-oneplus-camera.dtsi` (CAMSS node, CCI enabled, sensors, lenses, GPIO
  supplies, PM8998 LVS1, MCLK and pin states), included by `sdm845-oneplus-common.dtsi`.
- `patches/kernel/oneplus6.config`: all of it as modules. The built-in kernel does not change (the config
  differs only by `=m` lines), so the kernel already on the phone runs the new device tree and loads the new
  modules: no MODVERSIONS or module signing in this kernel, same source and config for everything built in.

## Build

After `03-apply-patches.sh` (which applies 0005-0007) and `04-build-kernel.sh`:

```sh
camera/build-tools.sh          # static aarch64 media-ctl and yavta (OH SDK clang + musl), pinned sources
camera/collect-test-files.sh   # modules, tools, phone scripts and a RAM-boot image into $WORK_DIR/camera-test
```

## Test (RAM boot, nothing flashed)

```sh
BOOT_IMG=$WORK_DIR/camera-test/boot-oneplus6-camera.img scripts/11-boot-oh.sh
camera/host-camera-test.sh push            # to /data/local/tmp/cam on the phone
camera/host-camera-test.sh load            # insmod; dmesg shows "imx376 N-0010 bound to msm_csiphy1"
camera/host-camera-test.sh capture tpg     # CAMSS alone: the CSID's colour-bar generator
camera/host-camera-test.sh capture imx376 10 2   # the sensor's colour bars (sensor + CSI-2 link)
camera/host-camera-test.sh capture imx376        # a picture; then imx371, then imx519 (C-PHY)
(. scripts/config.sh; hdc_ shell reboot)    # back to the installed kernel
```
`capture` sets up `sensor -> msm_csiphyN -> msm_csid0 -> msm_vfe0_rdi0 -> msm_vfe0_video0` with media-ctl,
captures RAW10 with yavta, pulls the last frames and converts them with `camera/raw2png.py` (half-resolution
demosaic, grey-world balance, gamma; prints per-channel statistics). Each step adds one block to the chain,
so the first one that fails names the broken part.
