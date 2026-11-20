# Cameras (OH 7.0 branch): kernel bring-up and on-phone test

Status: the kernel side is written and built, **not yet run on a phone**. The patches are a staged topic,
[`patches/staging/camera`](../patches/staging/camera), outside the default build: `STAGING=camera` applies and builds
them. This page says what they do and how to test them without flashing anything.

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
phone had no camera. The staged kernel patches (`patches/staging/camera/kernel/`) backport that tree:

- `kernel/0008`: CAMSS for SDM845 (CSIPHY incl. C-PHY, CSID gen2, VFE 17x, video nodes), reduced
  to SDM845 and ported to the 5.10 media core (`camss-compat.h`); each sensor is linked as soon as it
  binds, so one sensor failing does not hide the others.
- `kernel/0009`: the IMX519, IMX376K and IMX371 drivers, the lens driver (`lc89821x`), and the
  `v4l2-cci` register helpers (5.10 lacks them).
- `kernel/0010`: `sdm845-oneplus-camera.dtsi` (CAMSS node, CCI enabled, sensors, lenses, GPIO
  supplies, PM8998 LVS1, MCLK and pin states), included by `sdm845-oneplus-common.dtsi`.
- `kernel/camera.config`: all of it as modules. The built-in kernel does not change (the config
  differs only by `=m` lines), so the kernel already on the phone runs the new device tree and loads the new
  modules: no MODVERSIONS or module signing in this kernel, same source and config for everything built in.

## Build

With the staged topic applied (after the default patches) and the kernel built with its config fragment:

```sh
STAGING=camera scripts/03-apply-patches.sh
STAGING=camera scripts/04-build-kernel.sh
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

## OH camera HDI (rear IMX376K first)

The images have OH's camera framework, the Camera app and the camera host service, but the port never built a
camera VDI (its `camera/` directory was an unused Unisoc copy), so no camera was published. OH's V4L2 VDI
expects a camera with an ISP (YUV out of the video node, matched by driver name). CAMSS has no ISP and the
same driver name on every node, so the staged OH patches (`patches/staging/camera/oh/<project>/`) add:

- `device/board/oneplus/0007`: the V4L2 VDI in the board group (one camera, `imx376` = `lcam001`; the
  software pipeline nodes of OH's USB-camera VDI); `/vendor/bin/camss_setup imx376 1 0 0 0`, run once by init,
  links `msm_csiphy1 -> msm_csid0 -> msm_vfe0_rdi0` and sets the sensor's format on them; the camera modules
  installed and loaded at boot; `camera_host` may open `/dev/media*` and `/dev/v4l-subdev*`.
- `drivers/peripheral/0002`: OH's V4L2 adapter, for the nodes listed in `/vendor/etc/camera/camss_raw.cfg`
  only, matches the node by name, sets the raw Bayer format and converts each frame to YUV in software
  (demosaic by 2x2 binning, black level, grey-world white balance, gamma, scaling) with auto exposure on the
  sensor's exposure and gain controls.
- `vendor/oneplus/0006`: `camera_host_config.hcs` (one back camera, preview 1280x960/640x480, photo JPEG
  1280x960), the pipeline config, `camss_raw.cfg`, and the Camera app's `CameraProfiles.json`.
- `build/0004`: the build checks rk3568's camera VDI has (exec_script allowlist, part-deps whitelist).

The camera targets compile; the images with them have not been built or run yet. Images with cameras need
`STAGING=camera` for `03-apply-patches.sh` and `04-build-kernel.sh` (the board installs and loads the camera
modules), then `05-build-oh.sh`.
