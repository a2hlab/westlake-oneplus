# Reading a hung phone's RAM

A OnePlus 6 that hangs or panics under OH does not reboot by itself: Qualcomm's firmware takes it to crash-dump mode
and waits until it is restarted, with RAM as it was. On the PC it is the USB device `05c6:900e` ("QUSB_BULK" on
Windows, no driver); adb, fastboot and hdc are gone, and the screen is frozen or black. ramoops is of no help after
a restart (no record survives one on this phone), and at `loglevel=1` the console has emergencies only. But the
kernel's own log buffer, its tasks and TrustZone's diagnostic area are still in RAM, and
[`scripts/crashdump.py`](../scripts/crashdump.py) reads them over USB (Qualcomm's Sahara protocol, memory-debug
mode). [`scripts/recover-phone.sh`](../scripts/recover-phone.sh) makes a whole capture, restarts the phone and waits
for OH. Nothing is written to the phone.

## Before a hang: the kernel's symbols

`crashdump.py kmsg` needs the `System.map` of the kernel that is running; `04-build-kernel.sh` leaves it in
`KERNEL_OUT`. Two more files make the capture complete:

- `offsets.json`, the structure offsets for the task and run-queue walk (tasks, stacks):
  `scripts/crashdump.py offsets $KERNEL_OUT/vmlinux > offsets.json` (needs `pahole`)
- `banner.txt`, the kernel's `Linux version ...` line (`strings $KERNEL_OUT/vmlinux | grep -m1 '^Linux version'`):
  the capture checks it against the kernel in RAM

Keep the three files with every kernel you install (`recover-phone.sh` takes them from `KERNEL_SYMS`, default
`$KERNEL_OUT`). Without `--banner`, `kmsg` still checks that the System.map's `linux_banner` holds a version string,
which another build's map rarely passes.

## Capturing

- **Linux:** the device node must be writable (a udev rule for `05c6:900e`, or root); `crashdump.py` needs `pyusb`
  and libusb-1.0 (a Python venv with `pyusb` is enough).
- **WSL:** give the device to Linux with [usbipd-win](https://github.com/dorssel/usbipd-win): `usbipd bind --busid
  <BUSID>` once as administrator, then `usbipd attach --wsl --busid <BUSID>` (BUSID from `usbipd list`), and make
  the node writable (`wsl -u root chmod a+rw /dev/bus/usb/<bus>/<device>`). Each Sahara session needs the device
  attached afresh: a session that has ended, well or not, answers no HELLO until the device is detached, unbound,
  bound and attached again. `recover-phone.sh` does that before each step (`USBIPD`: usbipd.exe).

One session each:

```sh
scripts/crashdump.py kmsg DIR --system-map MAP --offsets offsets.json --banner banner.txt --no-image
scripts/crashdump.py console DIR   # the ramoops area: panic records, console.txt
scripts/crashdump.py reset         # restart; the phone boots its default slot
```

or `scripts/recover-phone.sh` for all of it (settings in its header). It then waits until OH has booted: with OH in
`boot_b` (oh-7.0 branch, `13-flash-boot.sh`) the phone starts it by itself; otherwise it RAM-boots OH with
`11-boot-oh.sh`, but only when `SERIAL` names the phone. `recover-phone.sh --check` only says whether a phone is in
crash-dump mode. Corpus rounds call it from `westlake/tools/supervise-round.sh`. On 2026-11-19 `kmsg` read a
deliberate panic in 3.2 s (4609 log records, 1243 tasks); a whole recovery with the restart and OH's boot took about
5 minutes.

## What a capture holds

| file | what |
|---|---|
| `dmesg-ram.txt` | the kernel's log ring: every message, whatever the loglevel, including a record the reset cut short |
| `ram/summary.txt` | where the kernel was found (and its KASLR offset), the last 40 log lines, per-CPU printk buffers not yet in the ring, the reset-reason regions (PMIC power-on reasons, reset status), the TrustZone counters that fired, the tasks in D state, when `watchdog_service` last ran |
| `ram/cpus.txt` | per CPU: online, run-queue lock, running and uninterruptible counts, run-queue clock, the current task |
| `ram/tasks.tsv` | every thread: state, CPU, priority, policy, how long ago it last ran, ... |
| `ram/stacks.txt` | the stacks of running and D-state tasks, with symbols |
| `ram/tzdiag.txt` | TrustZone's diagnostic area (per-CPU boot and reset entries, interrupt counts per CPU, TrustZone's log) and the AOP's log; their times also on the kernel's clock |
| `ram/regions/` | the small memory regions (OCIMEM, the AOP's data RAM, ...); `crashdump.py tzdiag ram/regions/OCIMEM.BIN` decodes TrustZone's area again |
| `console.txt` | the ramoops console zone: only what reached a console |

`crashdump.py kmsg-file` does the same from RAM images on disk (a full RAM dump, tests).

## Reading it

1. The end of `dmesg-ram.txt`, without the usual noise (`access tokenid magic fail`, SELinux `audit: type=1400`,
   `kauditd_printk_skb`).
2. `cpus.txt`: what each CPU ran at the end. A run-queue clock that stopped seconds before the others marks a CPU that
   stopped taking ticks.
3. `tasks.tsv`, `stacks.txt`: the tasks in D state and where they wait (e.g. writeback in `blk_mq_get_tag`: storage
   requests that never complete).
4. `tzdiag.txt`, against the baseline below.

### TrustZone's counters: what every capture shows

An interrupt row is: number, TrustZone's name for it (7 characters), the count on CPU 0 to 7. `crashdump.py` marks
rows that fired; TrustZone's own watchdog bark (`SWDogBa`), CPU wakeups and the PDC are routine. A deliberate panic
(`echo c > /proc/sysrq-trigger`, 2026-11-19) shows what entering crash-dump mode leaves by itself:

```
reset entries (per CPU: type, count):
  cpu2 type 0x33 count 1
interrupts: number, name, count per CPU
  15   SGIRese               1      1      0      1      1      1      1      1   <-- fired
  13   SGIFata               0      0      1      0      0      0      0      0   <-- fired
  226  NOCERR                0      1      0      0      0      0      0      0   <-- fired
```

- NoC error #226 once (on CPU0 or CPU1), SGIReset on some CPUs, and SGIFatal with a reset entry of type 0x33 on one
  CPU were in every capture of 2026-11-19, the deliberate panic's included: on their own they say nothing about the
  cause.
- The CPU with SGIFatal and the type 0x33 entry does: it was the one that panicked (above: CPU2 ran the `sh` that
  wrote to sysrq-trigger), and in each hang with a task walk the one whose task was stuck in a memory access.
- Anything beyond the baseline is the signal. In the hangs of 2026-11-19 that was NoC error #186 (a bus error),
  several times, in two of seven captures. Non-secure watchdog bites (`NSWDogB`), XPU violations (`SPI XPU`), the
  RPM watchdog and RPM errors stayed at zero.

TrustZone's and the AOP's log times are the 19.2 MHz system counter's, counted from power-on; the kernel's clock
starts a few seconds later. `kmsg` reads the offset between the two from the kernel (sched_clock's epoch) and gives
every TrustZone and AOP time on the kernel's clock as well, so that they line up with `dmesg-ram.txt` (on 2026-11-19:
bus errors 53 ms before the audio DSP reported its crash).

## A worked example

The `oh-7.0` branch's [`docs/hang-2026-11-19.md`](https://github.com/a2hlab/westlake-oneplus/blob/oh-7.0/docs/hang-2026-11-19.md):
these captures, two stress scripts and a probe module traced the phone's hangs to 26 MB of firmware-protected memory
in the kernel's memory map (kernel patch `0011`).
