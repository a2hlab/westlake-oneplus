#!/usr/bin/env python3
"""crashdump.py console OUTDIR | table | reset: a OnePlus 6 that hung or panicked under OpenHarmony waits in
Qualcomm crash-dump mode (USB 05c6:900e, "QUSB_BULK" on Windows, no driver). This reads the kernel's console log
from its RAM, which is gone after a restart, and resets the phone.

  console OUTDIR  read the ramoops area (0xac300000, 2 MB: panic records, then the console zone) into OUTDIR,
                  and write the console log, oldest line first, to OUTDIR/console.txt
  table           list the memory regions the phone offers
  reset           restart the phone (it boots its default slot: Android; scripts/11-boot-oh.sh then boots OH)

Under WSL, give the device to Linux first with usbipd-win (Windows, administrator):
  usbipd bind --busid <BUSID>; usbipd attach --wsl --busid <BUSID>   (BUSID from `usbipd list`, VID:PID 05c6:900e)
and make its node writable (wsl -u root chmod a+rw /dev/bus/usb/<bus>/<dev>). Needs pyusb and libusb-1.0.

The bootloader's own "KMSG region" (0xac44000c) assumes the stock Android kernel's ramoops layout; the mainline
kernel this port runs puts its panic records first (6 x 256 KB), then the console (256 KB at 0xac480000), ftrace and
pmsg, so the console is read from there. With ECC off (patches/kernel/0003) the console zone is plain text.

Protocol (Qualcomm Sahara, little endian): the phone sends HELLO, the host answers HELLO_RESP with mode 2 (memory
debug), the phone sends MEMORY_DEBUG(_64) with its region table, the host reads memory with MEMORY_READ(_64) and ends
with RESET. A read whose length is a multiple of 512 ends with a zero-length packet that the host must read: the
phone sends nothing else until it has. Each run needs a fresh session: one that ended badly answers no HELLO until
the device is attached again (usbipd detach and attach)."""
import os
import struct
import sys

import usb.core
import usb.util

HELLO, HELLO_RESP, RESET, RESET_RESP, END_TRANSFER = 0x01, 0x02, 0x07, 0x08, 0x04
MEMORY_DEBUG, MEMORY_READ, MEMORY_DEBUG_64, MEMORY_READ_64 = 0x09, 0x0A, 0x10, 0x11
MODE_MEMORY_DEBUG = 2
CHUNK = 0x10000
RAMOOPS, RAMOOPS_SIZE = 0xAC300000, 0x200000
ZONE = 0x40000
CONSOLE_OFFSET = 6 * ZONE

dev = usb.core.find(idVendor=0x05C6, idProduct=0x900E)
if dev is None:
    sys.exit('no phone in crash-dump mode (USB 05c6:900e)')
try:
    if dev.is_kernel_driver_active(0):
        dev.detach_kernel_driver(0)
except (usb.core.USBError, NotImplementedError):
    pass
dev.set_configuration()
intf = dev.get_active_configuration()[(0, 0)]
ep_out = usb.util.find_descriptor(
    intf, custom_match=lambda e: usb.util.endpoint_direction(e.bEndpointAddress) == usb.util.ENDPOINT_OUT)
ep_in = usb.util.find_descriptor(
    intf, custom_match=lambda e: usb.util.endpoint_direction(e.bEndpointAddress) == usb.util.ENDPOINT_IN)


def read(n=4096, timeout=5000):
    return bytes(ep_in.read(n, timeout=timeout))


def write(data):
    ep_out.write(data, timeout=5000)


def handshake():
    """HELLO, HELLO_RESP in memory-debug mode; returns (64-bit, table address, table length)."""
    pkt = read()
    cmd = struct.unpack_from('<I', pkt)[0]
    if cmd != HELLO:
        sys.exit('expected HELLO, got command 0x%x' % cmd)
    version, compatible = struct.unpack_from('<II', pkt, 8)
    write(struct.pack('<IIIIII', HELLO_RESP, 0x30, version, compatible, 0, MODE_MEMORY_DEBUG) + b'\0' * 24)
    pkt = read()
    cmd = struct.unpack_from('<I', pkt)[0]
    if cmd == MEMORY_DEBUG_64:
        return (True,) + struct.unpack_from('<QQ', pkt, 8)
    if cmd == MEMORY_DEBUG:
        return (False,) + struct.unpack_from('<II', pkt, 8)
    sys.exit('expected MEMORY_DEBUG, got command 0x%x' % cmd)


def memread(wide, addr, size):
    data = bytearray()
    while len(data) < size:
        n = min(CHUNK, size - len(data))
        if wide:
            write(struct.pack('<IIQQ', MEMORY_READ_64, 0x18, addr + len(data), n))
        else:
            write(struct.pack('<IIII', MEMORY_READ, 0x10, addr + len(data), n))
        got = bytearray()
        while len(got) < n:
            part = read(n - len(got), timeout=20000)
            if not got and len(part) == 0x10 and n != 0x10 and struct.unpack_from('<I', part)[0] == END_TRANSFER:
                sys.exit('the phone refused a read at 0x%x (status %d)' % (addr + len(data), struct.unpack_from('<I', part, 12)[0]))
            got += part
        if n % 512 == 0:
            try:
                ep_in.read(512, timeout=1000)   # the zero-length packet that ends the transfer
            except usb.core.USBTimeoutError:
                pass
        data += got
    return bytes(data)


def regions(wide, addr, size):
    raw = memread(wide, addr, size)
    entry = 64 if wide else 52
    rows = []
    for i in range(0, len(raw) - entry + 1, entry):
        if wide:
            base, length = struct.unpack_from('<QQ', raw, i + 8)
            desc, name = raw[i + 24:i + 44], raw[i + 44:i + 64]
        else:
            base, length = struct.unpack_from('<II', raw, i + 4)
            desc, name = raw[i + 12:i + 32], raw[i + 32:i + 52]
        rows.append((base, length, desc.split(b'\0')[0].decode(errors='replace').strip(),
                     name.split(b'\0')[0].decode(errors='replace')))
    return rows


def reset():
    write(struct.pack('<II', RESET, 8))
    try:
        answer = struct.unpack_from('<I', read(timeout=5000))[0]
        print('reset' if answer == RESET_RESP else 'reset: answer 0x%x' % answer)
    except usb.core.USBError as e:
        print('reset sent; no answer (%s)' % e)


action = sys.argv[1] if len(sys.argv) > 1 else ''
if action not in ('console', 'table', 'reset'):
    sys.exit(__doc__)
wide, table_addr, table_size = handshake()
if action == 'table':
    for base, length, desc, name in regions(wide, table_addr, table_size):
        print('0x%012x %10d KB  %-22s %s' % (base, length >> 10, desc, name))
elif action == 'console':
    out = sys.argv[2]
    os.makedirs(out, exist_ok=True)
    area = memread(True, RAMOOPS, RAMOOPS_SIZE)
    open(os.path.join(out, 'ramoops.bin'), 'wb').write(area)
    sig, start, used = struct.unpack_from('<4sII', area, CONSOLE_OFFSET)
    if sig != b'DBGC':
        sys.exit('no console zone at 0x%x (signature %r)' % (RAMOOPS + CONSOLE_OFFSET, sig))
    data = area[CONSOLE_OFFSET + 12:CONSOLE_OFFSET + ZONE]
    text = data[start:used] + data[:start] if used == len(data) else data[:used]
    open(os.path.join(out, 'console.txt'), 'wb').write(text.replace(b'\0', b''))
    records = sum(1 for i in range(6) if struct.unpack_from('<4sII', area, i * ZONE)[2])
    print('console: %d bytes -> %s/console.txt; %d panic records' % (len(text), out, records))
else:
    reset()
