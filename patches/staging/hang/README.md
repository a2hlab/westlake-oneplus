# Staged: hang

The phone hangs into Qualcomm crash-dump mode under sustained storage writes. [`io-stress.sh`](io-stress.sh) (a
copy of `/system/lib64` tarred onto `/data` and unpacked, then a 1 GB fsync'd write, in a loop) hung it within a
minute on the release kernel with no app running (2026-11-19); long corpus rounds hung it every few hours. The RAM
captures of the main branch (`scripts/crashdump.py kmsg`, `scripts/recover-phone.sh`) show the UFS host no longer
completing commands (the writeback worker waits for a request tag in `blk_mq_get_tag`; every tag is taken), then a
bus error (TrustZone's NOC error interrupt #186). The cause is not found yet. These changes came out of looking for
it; none is in the default build.

| item | what | state | before promotion |
|---|---|---|---|
| [`kernel/0005`](kernel/0005-access-tokenid-quiet-terminal-probes.patch) | `/dev/access_token_id` answers foreign ioctls (`isatty`/`TIOCGWINSZ` probes from services and apps, many a second) with `ENOTTY` and no error line; they were 39 % of the kernel log in a round, and at a console loglevel above 1 the flood froze the phone | built; booted once on the phone in the test kernel with `0005`-`0007` (below), not evaluated | a round whose kernel log has no `access tokenid magic fail` lines, and no service or app that minds `ENOTTY` (it was `EINVAL`) |
| [`kernel/0006`](kernel/0006-fastrpc-cb-remove-session-0.patch) | fastrpc invalidates session 0 too when a compute context bank goes away (fixed in later 5.10 stable releases); it runs when a DSP restarts | built; booted once (same test kernel); its path not exercised (`westlake/03-prep.sh` on main keeps DSP restarts off) | a DSP restart (remoteproc recovery on; a DSP crash, or a stop and start) without fastrpc errors |
| [`kernel/0007`](kernel/0007-ufs-qcom-interconnect-votes.patch) | the UFS host votes interconnect bandwidth for its DMA and register path, as v6.x does | **ran on the phone, did not help** (2026-11-19): with the votes in place (`interconnect_summary` lists `1d84000.ufshc`), `io-stress.sh` hung the phone within seconds; no NOC error #186 this time, so it changes how the hang shows, not whether | only as part of a fix that survives `io-stress.sh` |
| [`kernel/hang.config`](kernel/hang.config) | soft-lockup and workqueue-stall reports in the kernel log (reporting only) | not run: it changes the built-in kernel, so it needs a kernel and module build (`STAGING=hang scripts/04-build-kernel.sh`) and images with those modules | a boot and a round with the reports on and no false reports |
| `log_buf_len=4M` | a 4 MB kernel log ring instead of 512 KB (about 10 minutes of a round): `BOOT_CMDLINE_EXTRA=log_buf_len=4M scripts/06-make-boot.sh`; `crashdump.py kmsg` reads the ring wherever it is | not run on the phone | a boot with it, and a crash-dump capture that reads the whole ring |

The code patches can be tried without new modules: build only `Image.gz` and the enchilada DTB in a separate out
directory with the release kernel's `.config` unchanged (`make ... olddefconfig Image.gz
qcom/sdm845-oneplus-enchilada.dtb`), so the modules on the phone still fit; make a boot image with that kernel and the
installed ramdisk and RAM-boot it (`BOOT_IMG=... scripts/11-boot-oh.sh`). Nothing is flashed; a reset returns to the
installed kernel. That is how `0005`-`0007` ran.

Root cause found on 2026-11-19 evening: not the UFS host but the device tree's memory map. The kernel was given 26 MB of firmware-protected memory (0x89100000-0x8aafffff); patches/kernel/0011 (default build) reserves it as mainline does, and the storage and memory stresses then pass. 0005 (quiet access-token probes) and 0006 (fastrpc session 0) remain optional improvements; 0007 is not needed.
