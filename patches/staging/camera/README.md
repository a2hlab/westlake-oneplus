# Staged: camera

The OnePlus 6's three cameras under OH 7.0: a 5.10 backport of the sdm845-mainline tree's camera support (kernel)
and OH's camera HDI for the first camera, the rear IMX376K. Written and built on 2026-11-19; nothing has run on the
phone yet. [`docs/camera.md`](../../../docs/camera.md) has the hardware, what each patch does, the build and the
RAM-boot test (nothing flashed: the installed kernel image with the camera DTB, the modules loaded by hand);
[`camera/`](../../../camera) has its tools (`build-tools.sh`, `collect-test-files.sh`, `host-camera-test.sh`, the
phone-side scripts, `raw2png.py`, `rebuild-boot-from.sh`).

| item | what | state | before promotion |
|---|---|---|---|
| [`kernel/0008`](kernel/0008-media-camss-sdm845-backport.patch) | CAMSS for SDM845 (CSIPHY incl. C-PHY, CSID gen2, VFE 17x), reduced to SDM845 and ported to 5.10's media core; module parameter `enable_gcc_axi` (off) | built (module), not run | the RAM-boot test: modules load, the CSID test pattern is captured (`host-camera-test.sh capture tpg`) |
| [`kernel/0009`](kernel/0009-media-oneplus6-camera-sensors.patch) | the IMX519, IMX376K and IMX371 drivers, the LC898217XC lens driver, `v4l2-cci` | built (modules), not run | each sensor binds (`bound to msm_csiphyN`) and gives its test pattern and a picture; IMX376K and IMX371 (D-PHY) first, IMX519 (C-PHY, the least proven path) last |
| [`kernel/0010`](kernel/0010-arm64-dts-oneplus6-cameras.patch) | device tree: CAMSS node, the camera I2C controller (CCI) on, sensors, lenses, supplies, pins | built; not booted | the phone boots with it and otherwise as before (display, Wi-Fi, sound); the CCI and its clients appear |
| [`kernel/camera.config`](kernel/camera.config) | the drivers as modules: the built-in kernel and its module ABI stay the same | built | with `0008`-`0010` |
| [`oh/device/board/oneplus/0007`](oh/device/board/oneplus/0007-oneplus6-cameras.patch) | the V4L2 camera VDI in the board group (one camera, `imx376`), `camss_setup` (the media graph at boot), the camera modules installed and loaded at boot, `camera_host`'s access to `/dev/media*` and `/dev/v4l-subdev*` | the camera targets build (an isolated build of the patched tree); not in images | `camss_setup` checked on the RAM-booted phone (`host-camera-test.sh verify-setup`), then images with this topic: the Camera app lists the camera, previews and saves a photo |
| [`oh/drivers/peripheral/0002`](oh/drivers/peripheral/0002-camera-v4l2-raw-bayer.patch) | OH's V4L2 adapter converts raw Bayer to YUV in software (demosaic, black level, white balance, gamma, auto exposure), only for the nodes `camss_raw.cfg` lists | builds; the conversion was checked on a PC only | preview rate and picture on the phone |
| [`oh/vendor/oneplus/0006`](oh/vendor/oneplus/0006-fajita-camera-hdi.patch) | `camera_host_config.hcs` (one back camera), the pipeline config, `camss_raw.cfg`, the Camera app's `CameraProfiles.json` | builds | with the board patch |
| [`oh/build/0004`](oh/build/0004-camera-vdi-build-checks.patch) | the build checks rk3568's camera VDI has (exec_script allowlist, part-deps whitelist) | the build passes with it | with the board patch |

Numbers: the kernel patches follow the default `0001`-`0004` and the staged `hang` topic's `0005`-`0007` (on the
branch they were written on they were `0005`-`0007`); the OH patches continue their projects' default series.
The modules need the kernel they were built for (same source and config for everything built in; this kernel has no
MODVERSIONS or module signing). Before SELinux enforces, `camera_host` and `camss_setup` need policy (the images run
permissive).
