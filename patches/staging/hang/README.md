# Staged: hang

The phone hung into Qualcomm crash-dump mode under memory pressure: within a minute of a storage or memory stress,
every few hours in long corpus rounds (2026-11-18/19). The cause was the device tree's memory map, which gave the
kernel 26 MB of memory the firmware protects (0x89100000-0x8aafffff); [`kernel/0011`](../../kernel/0011-oneplus6-reserved-memory-as-mainline.patch) in the default
build reserves memory as mainline does, and the stresses below then pass. [docs/hang-2026-11-19.md](../../../docs/hang-2026-11-19.md)
is the record of the investigation.

The kernel changes here came out of the search before the cause was known; none is in the default build. `0005`
and `0006` remain optional improvements, `0007` is not needed:

| item | what | state | before promotion |
|---|---|---|---|
| [`kernel/0005`](kernel/0005-access-tokenid-quiet-terminal-probes.patch) | `/dev/access_token_id` answers foreign ioctls (`isatty`/`TIOCGWINSZ` probes from services and apps, many a second) with `ENOTTY` and no error line; they were 39 % of the kernel log in a round, and at a console loglevel above 1 the flood froze the phone | built; booted once on the phone in the test kernel with `0005`-`0007` (below), not evaluated | a round whose kernel log has no `access tokenid magic fail` lines, and no service or app that minds `ENOTTY` (it was `EINVAL`) |
| [`kernel/0006`](kernel/0006-fastrpc-cb-remove-session-0.patch) | fastrpc invalidates session 0 too when a compute context bank goes away (fixed in later 5.10 stable releases); it runs when a DSP restarts | built; booted once (same test kernel); its path not exercised (`westlake/03-prep.sh` on main keeps DSP restarts off) | a DSP restart (remoteproc recovery on; a DSP crash, or a stop and start) without fastrpc errors |
| [`kernel/0007`](kernel/0007-ufs-qcom-interconnect-votes.patch) | the UFS host votes interconnect bandwidth for its DMA and register path, as v6.x does | **ran on the phone, did not help, not needed** (2026-11-19): with the votes in place (`interconnect_summary` lists `1d84000.ufshc`), `io-stress.sh` hung the old memory map within seconds | only if a UFS problem of its own shows up |
| [`kernel/hang.config`](kernel/hang.config) | soft-lockup and workqueue-stall reports in the kernel log (reporting only) | not run: it changes the built-in kernel, so it needs a kernel and module build (`STAGING=hang scripts/04-build-kernel.sh`) and images with those modules | a boot and a round with the reports on and no false reports |
| `log_buf_len=4M` | a 4 MB kernel log ring instead of 512 KB (about 10 minutes of a round): `BOOT_CMDLINE_EXTRA=log_buf_len=4M scripts/06-make-boot.sh`; `crashdump.py kmsg` reads the ring wherever it is | not run on the phone | a boot with it, and a crash-dump capture that reads the whole ring |

The code patches can be tried without new modules: [`scripts/test-kernel.sh`](../../../scripts/test-kernel.sh)
builds `Image.gz` and the enchilada DTB in a separate directory with the phone kernel's `.config` unchanged, so the
modules on the phone still fit, and makes a boot image with the installed ramdisk and command line, to RAM-boot
(`BOOT_IMG=... scripts/11-boot-oh.sh`). Nothing is flashed; a reset returns to the installed kernel. That is how
`0005`-`0007` ran.

The tools that found the cause; none of them is built or installed by the scripts:

| tool | what |
|---|---|
| [`mem-stress.sh`](mem-stress.sh) | on the phone: fills a tmpfs with zeros again and again (no storage I/O). Hung the old map in about 30 s; `mem-stress.sh 4 10` ran its 10 minutes with `0011` |
| [`io-stress.sh`](io-stress.sh) | on the phone: `/system/lib64` tarred onto `/data` and unpacked, then a 1 GB fsync'd write, in a loop. Hung the old map within a minute; `io-stress.sh 15` ran its 15 minutes with `0011` |
| [`guardprobe/`](guardprobe) | a kernel module that reads one word of a physical page through the kernel's linear map: a read that never completes (the phone ends in crash-dump mode) is memory the firmware protects. `guardprobe/build.sh` builds it for the kernel of `04-build-kernel.sh` |
