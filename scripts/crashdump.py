#!/usr/bin/env python3
"""crashdump.py console OUTDIR | kmsg OUTDIR --system-map MAP [...] | table | reset: a OnePlus 6 that hung or
panicked under OpenHarmony waits in Qualcomm crash-dump mode (USB 05c6:900e, "QUSB_BULK" on Windows, no driver).
This reads what the kernel left in RAM, which is gone after a restart, and resets the phone.

  console OUTDIR  read the ramoops area (0xac300000, 2 MB: panic records, then the console zone) into OUTDIR,
                  and write the console log, oldest line first, to OUTDIR/console.txt
  kmsg OUTDIR --system-map MAP [--kernel IMAGE] [--offsets JSON] [--budget SECONDS] [--base ADDR] [--no-image]
                  find the running kernel in RAM and read its own log buffer: every message, whatever the
                  console loglevel (OUTDIR/dmesg-ram.txt); then, in OUTDIR/ram/, the reset-reason regions,
                  TrustZone's and the AOP's diagnostics (tzdiag.txt), the tasks and run queues with stacks (needs
                  --offsets), the other small regions and the kernel image; summary.txt has the main findings
  kmsg-file OUTDIR --ram ADDR=FILE [--ram ...] --system-map MAP [...]
                  the same from RAM images on disk (a full RAM dump, tests)
  offsets VMLINUX print the structure offsets that 'kmsg' needs, as JSON (from vmlinux's DWARF; needs pahole)
  tzdiag FILE [--aop DATARAM] [--offset SECONDS]
                  decode TrustZone's diagnostic area from a saved OCIMEM region (OCIMEM.BIN): per-CPU boot and
                  reset entries, interrupt counts (non-secure watchdog bite, NOC errors, XPU violations) and TZ's
                  log; with the AOP's data RAM (DATARAM.BIN) the AOP's log too. Their times are the system counter's;
                  with the counter's offset to the kernel clock (kmsg reads it: summary.txt, printk/layout.json) also
                  the kernel's. In a kmsg capture's ram/regions/ both are found by themselves
  table           list the memory regions the phone offers
  reset           restart the phone (it boots its default slot)

Under WSL, give the device to Linux first with usbipd-win (Windows, administrator):
  usbipd bind --busid <BUSID>; usbipd attach --wsl --busid <BUSID>   (BUSID from `usbipd list`, VID:PID 05c6:900e)
and make its node writable (wsl -u root chmod a+rw /dev/bus/usb/<bus>/<dev>). Needs pyusb and libusb-1.0.

The bootloader's own "KMSG region" (0xac44000c) assumes the stock Android kernel's ramoops layout; the mainline
kernel this port runs puts its panic records first (6 x 256 KB), then the console (256 KB at 0xac480000), ftrace and
pmsg, so the console is read from there. With ECC off (patches/kernel/0003) the console zone is plain text. The
console zone only has what reached a console, so with loglevel=1 on the command line it has emergencies only.

kmsg: the kernel's printk ring buffer (5.10: a descriptor ring, an info ring and a text ring) holds every message.
The bootloader chooses the kernel's physical address (this phone's: 0x80080000, not 2 MB aligned); kmsg tries it
first, then looks for the arm64 Image header ("ARM\\x64" at 0x38, with the image size System.map gives) in 64 KB steps
of the DDR regions of the phone's table, and checks linux_banner there. KASLR moves the kernel's virtual addresses: kimage_vaddr (the run-time address of _text),
kimage_voffset and memstart_addr, read from the image, translate kernel-image, linear-map and (through the page
tables at swapper_pg_dir) vmalloc addresses. Everything comes from the matching System.map; the task walk also needs
the structure offsets of the same build (`offsets VMLINUX > offsets.json`).

Protocol (Qualcomm Sahara, little endian): the phone sends HELLO, the host answers HELLO_RESP with mode 2 (memory
debug), the phone sends MEMORY_DEBUG(_64) with its region table, the host reads memory with MEMORY_READ(_64) and ends
with RESET. A read whose length is a multiple of 512 ends with a zero-length packet that the host must read: the
phone sends nothing else until it has. Each run needs a fresh session: one that ended badly answers no HELLO until
the device is attached again (usbipd detach and attach)."""
import argparse
import bisect
import gzip
import json
import mmap
import os
import re
import struct
import subprocess
import sys
import time

HELLO, HELLO_RESP, RESET, RESET_RESP, END_TRANSFER = 0x01, 0x02, 0x07, 0x08, 0x04
MEMORY_DEBUG, MEMORY_READ, MEMORY_DEBUG_64, MEMORY_READ_64 = 0x09, 0x0A, 0x10, 0x11
MODE_MEMORY_DEBUG = 2
CHUNK = 0x10000
RAMOOPS, RAMOOPS_SIZE = 0xAC300000, 0x200000
ZONE = 0x40000
CONSOLE_OFFSET = 6 * ZONE
# The OnePlus 6 (8 GB) table: four 2 GB DDR regions. Used when the table cannot be read.
DDR_DEFAULT = [(0x80000000, 1 << 31), (0x100000000, 1 << 31), (0x180000000, 1 << 31), (0x200000000, 1 << 31)]
IMAGE_ALIGN = 0x10000           # the Image needs 64 KB; this phone's bootloader puts it at 0x80080000
KNOWN_BASES = (0x80080000, 0x80000000)
STACK_SIZE = 0x4000            # arm64 THREAD_SIZE with 4 KB pages, no KASAN
DESC_SIZE, INFO_SIZE = 24, 88  # struct prb_desc, struct printk_info (5.10)
STATES = {0: 'reserved', 1: 'committed', 2: 'finalized', 3: 'reusable'}


class Refused(Exception):
    """The phone (or a RAM image) has no such memory."""


# ---------------------------------------------------------------------------------------------------- memory


class Sahara:
    """A Sahara memory-debug session with the phone."""

    def __init__(self):
        import usb.core
        import usb.util
        self.usb = usb
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
        out = usb.util.ENDPOINT_OUT
        self.ep_out = usb.util.find_descriptor(
            intf, custom_match=lambda e: usb.util.endpoint_direction(e.bEndpointAddress) == out)
        self.ep_in = usb.util.find_descriptor(
            intf, custom_match=lambda e: usb.util.endpoint_direction(e.bEndpointAddress) != out)
        self.wide, self.table_addr, self.table_size = True, 0, 0
        self.bytes_read = 0
        self.dead = None

    def _read(self, n=4096, timeout=5000):
        return bytes(self.ep_in.read(n, timeout=timeout))

    def _write(self, data):
        self.ep_out.write(data, timeout=5000)

    def handshake(self):
        """HELLO, HELLO_RESP in memory-debug mode; then the phone names its region table."""
        pkt = self._read()
        cmd = struct.unpack_from('<I', pkt)[0]
        if cmd != HELLO:
            sys.exit('expected HELLO, got command 0x%x' % cmd)
        version, compatible = struct.unpack_from('<II', pkt, 8)
        self._write(struct.pack('<IIIIII', HELLO_RESP, 0x30, version, compatible, 0, MODE_MEMORY_DEBUG) + b'\0' * 24)
        pkt = self._read()
        cmd = struct.unpack_from('<I', pkt)[0]
        if cmd == MEMORY_DEBUG_64:
            self.wide = True
            self.table_addr, self.table_size = struct.unpack_from('<QQ', pkt, 8)
        elif cmd == MEMORY_DEBUG:
            self.wide = False
            self.table_addr, self.table_size = struct.unpack_from('<II', pkt, 8)
        else:
            sys.exit('expected MEMORY_DEBUG, got command 0x%x' % cmd)

    def read(self, addr, size):
        if self.dead:
            raise Refused('no more reads: %s' % self.dead)
        try:
            return self._memread(addr, size)
        except self.usb.core.USBError as e:   # a timeout ends the session: later reads would only wait
            self.dead = 'the session stopped answering (%s)' % e
            raise

    def _memread(self, addr, size):
        data = bytearray()
        while len(data) < size:
            n = min(CHUNK, size - len(data))
            at = addr + len(data)
            if self.wide:
                self._write(struct.pack('<IIQQ', MEMORY_READ_64, 0x18, at, n))
            else:
                self._write(struct.pack('<IIII', MEMORY_READ, 0x10, at, n))
            got = bytearray()
            while len(got) < n:
                part = self._read(n - len(got), timeout=20000)
                if not got and len(part) == 0x10 and n != 0x10 and struct.unpack_from('<I', part)[0] == END_TRANSFER:
                    raise Refused('the phone refused a read at 0x%x (status %d)' % (at, struct.unpack_from('<I', part, 12)[0]))
                got += part
            if n % 512 == 0:
                try:
                    self.ep_in.read(512, timeout=1000)   # the zero-length packet that ends the transfer
                except self.usb.core.USBTimeoutError:
                    pass
            data += got
        self.bytes_read += size
        return bytes(data)

    def regions(self):
        raw = self.read(self.table_addr, self.table_size)
        entry = 64 if self.wide else 52
        rows = []
        for i in range(0, len(raw) - entry + 1, entry):
            if self.wide:
                base, length = struct.unpack_from('<QQ', raw, i + 8)
                desc, name = raw[i + 24:i + 44], raw[i + 44:i + 64]
            else:
                base, length = struct.unpack_from('<II', raw, i + 4)
                desc, name = raw[i + 12:i + 32], raw[i + 32:i + 52]
            rows.append((base, length, desc.split(b'\0')[0].decode(errors='replace').strip(),
                         name.split(b'\0')[0].decode(errors='replace')))
        return rows

    def reset(self):
        self._write(struct.pack('<II', RESET, 8))
        try:
            answer = struct.unpack_from('<I', self._read(timeout=5000))[0]
            print('reset' if answer == RESET_RESP else 'reset: answer 0x%x' % answer)
        except self.usb.core.USBError as e:
            print('reset sent; no answer (%s)' % e)


class RamFiles:
    """RAM images on disk (ADDR=FILE): a full dump, or a test image."""

    def __init__(self, specs):
        self.maps = []
        for spec in specs:
            addr, path = spec.split('=', 1)
            f = open(path, 'rb')
            self.maps.append((int(addr, 0), mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ)))
        self.bytes_read = 0

    def read(self, addr, size):
        for base, m in self.maps:
            if base <= addr and addr + size <= base + len(m):
                self.bytes_read += size
                return m[addr - base:addr - base + size]
        raise Refused('0x%x (+0x%x) is not in the RAM images' % (addr, size))

    def ddr(self):
        return [(base, len(m)) for base, m in self.maps]


def ddr_regions(rows):
    ddr = [(base, length) for base, length, desc, name in rows if name.upper().startswith('DDR') and length >= 1 << 26]
    return sorted(ddr) or DDR_DEFAULT


# ---------------------------------------------------------------------------------------------------- symbols


class SystemMap:
    def __init__(self, path):
        self.sym = {}
        text = []
        for line in open(path, errors='replace'):
            parts = line.split()
            if len(parts) < 3:
                continue
            addr, typ, name = int(parts[0], 16), parts[1], parts[2]
            if typ in 'nNaUw' or name.startswith(('$', '.L', '__efistub_')):
                continue
            self.sym.setdefault(name, addr)
            if typ in 'TtWw':
                text.append((addr, name))
        text.sort()
        self.text_addr = [a for a, _ in text]
        self.text_name = [n for _, n in text]
        self.etext = self.sym.get('_etext', 0)

    def __getitem__(self, name):
        return self.sym[name]

    def symbolize(self, addr):
        """addr is a link-time address; 'name+0xoff', or None outside the kernel's text."""
        init = self.sym.get('_sinittext', 0) <= addr < self.sym.get('_einittext', 0)
        if not self.text_addr or addr < self.text_addr[0] or (addr >= self.etext and not init):
            return None
        i = bisect.bisect_right(self.text_addr, addr) - 1
        return '%s+0x%x' % (self.text_name[i], addr - self.text_addr[i])


def load_kernel_file(path):
    """An arm64 Image, Image.gz (with or without an appended DTB) or a version-0 Android boot image -> Image."""
    raw = open(path, 'rb').read()
    if raw[:8] == b'ANDROID!':
        kernel_size, = struct.unpack_from('<I', raw, 8)
        page_size, = struct.unpack_from('<I', raw, 36)
        raw = raw[page_size:page_size + kernel_size]
    if raw[:2] == b'\x1f\x8b':
        import zlib
        raw = zlib.decompressobj(16 + zlib.MAX_WBITS).decompress(raw)
    if raw[0x38:0x3c] != b'ARM\x64':
        raise ValueError('%s: not an arm64 Image' % path)
    return raw


# ---------------------------------------------------------------------------------------------------- printk ring


def ring_text(begin, nxt, data, size_bits):
    """The text of one data block (5.10 kernel/printk/printk_ringbuffer.c get_data()): (bytes, block id, problem)."""
    size = 1 << size_bits
    if begin & 1 and nxt & 1:
        return (b'', None, None) if begin == 3 and nxt == 3 else (None, None, 'no data (failed reservation)')
    if begin >> size_bits == nxt >> size_bits and begin < nxt:
        off, n = begin & (size - 1), nxt - begin
    elif (begin + size) >> size_bits == nxt >> size_bits:
        off, n = 0, nxt & (size - 1)          # a wrapping block keeps its data at the start of the ring
    else:
        return None, None, 'bad block position %#x..%#x' % (begin, nxt)
    if begin % 8 or nxt % 8 or n < 8 or off + n > len(data):
        return None, None, 'bad block position %#x..%#x' % (begin, nxt)
    return data[off + 8:off + n], struct.unpack_from('<Q', data, off)[0], None


def parse_ring(count_bits, descs, infos, data, size_bits):
    """Every record a reader could still see, in sequence order, plus the ones a writer had reserved."""
    count = 1 << count_bits
    id_mask = (1 << 62) - 1
    records = []
    for i in range(count):
        sv, begin, nxt = struct.unpack_from('<QQQ', descs, i * DESC_SIZE)
        state, did = sv >> 62, sv & id_mask
        if state == 3 or did & (count - 1) != i:
            continue
        seq, ts, text_len, facility, bits, caller = struct.unpack_from('<QQHBBI', infos, i * INFO_SIZE)
        sub = infos[i * INFO_SIZE + 24:i * INFO_SIZE + 40].split(b'\0')[0]
        dev = infos[i * INFO_SIZE + 40:i * INFO_SIZE + 88].split(b'\0')[0]
        text, block_id, problem = ring_text(begin, nxt, data, size_bits)
        if text is None and state in (1, 2) and not begin & 7 and text_len:
            # The descriptor's text position is inconsistent, as when the cache line holding 'next' was still dirty
            # in a CPU cache at the reset: if the block at 'begin' carries this record's id, take text_len bytes.
            off = begin & ((1 << size_bits) - 1)
            if off + 8 + text_len <= len(data) and struct.unpack_from('<Q', data, off)[0] == did:
                text, block_id = data[off + 8:off + 8 + text_len], did
                problem = 'stale end position %#x: text taken from the block start' % nxt
        if text is not None:
            if block_id != did:
                problem = 'block id %#x, descriptor id %#x' % (block_id, did)
                text = None
            text = text[:text_len] if state else text.rstrip(b'\0')
        if seq % count != i:
            problem = (problem + '; ' if problem else '') + 'seq %d does not belong at index %d' % (seq, i)
        records.append({'seq': seq, 'ts': ts, 'level': bits >> 5, 'flags': bits & 0x1f, 'facility': facility,
                        'caller': caller, 'state': STATES[state], 'text': text, 'problem': problem,
                        'subsystem': sub.decode(errors='replace'), 'device': dev.decode(errors='replace')})
    records.sort(key=lambda r: r['seq'])
    return records


def dmesg_lines(records):
    out = []
    for r in records:
        ts = '[%5d.%06d] ' % (r['ts'] // 1000000000, r['ts'] % 1000000000 // 1000)
        mark = '' if r['state'] in ('committed', 'finalized') else '<%s> ' % r['state']
        if r['text'] is None:
            out.append(ts + mark + '<unreadable: %s>' % r['problem'])
            continue
        for line in r['text'].decode(errors='backslashreplace').split('\n'):
            out.append(ts + mark + line)
    return out


# ---------------------------------------------------------------------------------------------------- kernel


def state_char(state, exit_state):
    if exit_state & 32:
        return 'Z'
    if exit_state & 16:
        return 'X'
    if state == 0:
        return 'R'
    if state & 0x402 == 0x402:
        return 'I'
    for bit, ch in ((2, 'D'), (1, 'S'), (4, 'T'), (8, 't'), (0x40, 'P'), (0x80, 'X')):
        if state & bit:
            return ch
    return '?'


class Kernel:
    def __init__(self, mem, smap, log, offsets=None, image=None, va_bits=None):
        self.mem, self.map, self.log, self.off = mem, smap, log, offsets or {}
        self.text, self.end = smap['_text'], smap['_end']
        self.image_size = self.end - self.text
        self.image = image
        if va_bits is None:
            for bits in (48, 47, 52, 42, 39, 36):
                page_end = (1 << 64) - (1 << (bits - 1))
                if page_end <= self.text < page_end + (1 << 30):
                    va_bits = bits
                    break
            else:
                raise ValueError('cannot tell VA_BITS from _text %#x' % self.text)
        self.va_bits = va_bits
        self.page_offset = (1 << 64) - (1 << va_bits)
        self.page_end = (1 << 64) - (1 << (va_bits - 1))
        self.base = None
        self.tables = {}
        self.ddr = []
        self.banner_want = None

    # --- finding the kernel
    def check(self, addr):
        """None if the running kernel's image starts at addr, else why not."""
        head = self.mem.read(addr, 64)
        if head[0x38:0x3c] != b'ARM\x64':
            return 'no Image header'
        text_offset, image_size, flags = struct.unpack_from('<QQQ', head, 8)
        if image_size != self.image_size:
            return 'Image header: size %#x, System.map says %#x' % (image_size, self.image_size)
        if self.image is not None and head != self.image[:64]:
            return 'Image header differs from the kernel file'
        off = self.map['linux_banner'] - self.text
        banner = self.mem.read(addr + off, 256).split(b'\0')[0]
        want = self.banner_want
        if want is None and self.image is not None:
            want = self.image[off:off + 256].split(b'\0')[0]
        if want is not None:
            if banner.strip() != want.strip():
                return 'linux_banner differs: %r' % banner[:80]
        elif not banner.startswith(b'Linux version '):
            return 'no linux_banner: %r' % banner[:40]
        self.banner = banner.decode(errors='replace').strip()
        return None

    def candidates(self, ddr, base=None):
        seen = set()
        inside = lambda a: any(b <= a < b + l for b, l in ddr)
        for a in ((base,) if base is not None else ()) + KNOWN_BASES:
            if a not in seen and inside(a):
                seen.add(a)
                yield a
        for b, l in ddr:                         # sdm845: DDR from 0x80000000, the kernel low in it
            for a in range((b + IMAGE_ALIGN - 1) // IMAGE_ALIGN * IMAGE_ALIGN, min(b + l, b + 0x10000000), IMAGE_ALIGN):
                if a not in seen:
                    seen.add(a)
                    yield a
        for b, l in ddr:
            for a in range((b + 0x1fffff) // 0x200000 * 0x200000, b + l, 0x200000):
                if a not in seen:
                    yield a

    def find(self, ddr, base=None, deadline=None, scan_all=False):
        self.ddr = ddr
        found, probes, why = [], 0, {}
        for a in self.candidates(ddr, base):
            if deadline and time.time() > deadline:
                self.log('kernel search: out of time after %d probes' % probes)
                break
            probes += 1
            try:
                problem = self.check(a)
            except Refused as e:
                why[a] = str(e)
                continue
            if problem is None:
                found.append(a)
                if not scan_all:
                    break
            elif problem != 'no Image header':
                why[a] = problem
        for a, problem in list(why.items())[:8]:
            self.log('  candidate %#x: %s' % (a, problem))
        if len(found) > 1:
            self.log('kernel images at %s: taking the first' % ', '.join('%#x' % a for a in found))
        self.log('kernel search: %d probes, %s' % (probes, 'found at %#x' % found[0] if found else 'not found'))
        if not found:
            return None
        self.setup(found[0])
        return found[0]

    def setup(self, base):
        self.base = base
        self.kimage_vaddr = self.u64_img('kimage_vaddr')
        voffset = self.u64_img('kimage_voffset')
        self.memstart = struct.unpack('<q', self.img('memstart_addr', 8))[0]
        self.kaslr = self.kimage_vaddr - self.text
        self.voffset = self.kimage_vaddr - base
        if voffset != self.voffset:
            self.log('WARNING: kimage_voffset %#x, but kimage_vaddr - base = %#x' % (voffset, self.voffset))
        self.kstart = self.kimage_vaddr
        self.log('kernel: base %#x, KASLR offset %#x, kimage_voffset %#x, memstart_addr %#x, VA_BITS %d'
                 % (base, self.kaslr, self.voffset, self.memstart & ((1 << 64) - 1), self.va_bits))
        self.log('kernel: %s' % self.banner)

    # --- reading kernel memory
    def img(self, name, n):
        return self.read_pa(self.base + self.map[name] - self.text, n)

    def u64_img(self, name):
        return struct.unpack('<Q', self.img(name, 8))[0]

    def read_pa(self, pa, n):
        # Only memory the phone's table lists as DDR: a pointer from a half-updated structure must not turn into a
        # request the crash-dump loader was never asked for.
        if self.ddr and not any(b <= pa and pa + max(n, 64) <= b + l for b, l in self.ddr):
            raise Refused('%#x (+%#x) is outside DDR' % (pa, n))
        return self.mem.read(pa, max(n, 64))[:n]

    def walk(self, va):
        """Physical address of a kernel virtual address, through the page tables at swapper_pg_dir."""
        table = self.base + self.map['swapper_pg_dir'] - self.text
        for level, shift in enumerate((39, 30, 21, 12)):
            if table not in self.tables:
                self.tables[table] = self.read_pa(table, 4096)
            desc = struct.unpack_from('<Q', self.tables[table], ((va >> shift) & 0x1ff) * 8)[0]
            if not desc & 1:
                raise Refused('%#x is not mapped' % va)
            out = desc & 0x0000fffffffff000
            if level < 3 and not desc & 2:     # a block
                mask = (1 << shift) - 1
                return (out & ~mask) | (va & mask)
            table = out
        return table | (va & 0xfff)

    def va2pa(self, va):
        if self.kstart <= va < self.kstart + self.image_size:
            return va - self.voffset
        if self.page_offset <= va < self.page_end:
            return (va - self.page_offset) + self.memstart
        return self.walk(va)

    def read_va(self, va, n):
        if self.kstart <= va and va + n <= self.kstart + self.image_size or \
                self.page_offset <= va and va + n <= self.page_end:
            return self.read_pa(self.va2pa(va), n)
        out = bytearray()
        while len(out) < n:
            at = va + len(out)
            k = min(n - len(out), 4096 - (at & 0xfff))
            out += self.read_pa(self.walk(at), k)
        return bytes(out)

    def u64(self, va):
        return struct.unpack('<Q', self.read_va(va, 8))[0]

    def sym(self, name):
        """Run-time address of a symbol."""
        return self.map[name] + self.kaslr

    # --- what the kernel kept
    def printk_ring(self):
        prb = self.u64(self.sym('prb'))
        static = self.sym('printk_rb_static')
        if prb != static:
            self.log('printk: prb %#x (the static ring is %#x: a log_buf_len= ring)' % (prb, static))
        try:
            raw = self.read_va(prb, 80)
        except Refused as e:
            self.log('printk: prb unreadable (%s): the static ring instead' % e)
            prb, raw = static, self.read_va(static, 80)
        count_bits = struct.unpack_from('<I', raw, 0)[0]
        descs_va, infos_va, head_id, tail_id = struct.unpack_from('<QQQQ', raw, 8)
        size_bits = struct.unpack_from('<I', raw, 40)[0]
        data_va, head_lpos, tail_lpos, fail = struct.unpack_from('<QQQQ', raw, 48)
        if not (4 <= count_bits <= 24 and 10 <= size_bits <= 30):
            raise ValueError('printk ring at %#x: count_bits %d size_bits %d' % (prb, count_bits, size_bits))
        layout = {'prb': prb, 'count_bits': count_bits, 'descs': descs_va, 'infos': infos_va, 'head_id': head_id,
                  'tail_id': tail_id, 'size_bits': size_bits, 'data': data_va, 'head_lpos': head_lpos,
                  'tail_lpos': tail_lpos, 'fail': fail}
        count = 1 << count_bits
        descs = self.read_va(descs_va, count * DESC_SIZE)
        infos = self.read_va(infos_va, count * INFO_SIZE)
        data = self.read_va(data_va, 1 << size_bits)
        return layout, raw, descs, infos, data

    def percpu_offsets(self, n):
        return struct.unpack('<%dQ' % n, self.read_va(self.sym('__per_cpu_offset'), 8 * n))

    def percpu(self, name, offset):
        """Address of CPU's copy of a per-CPU variable (__per_cpu_offset values wrap around 2^64)."""
        return (self.sym(name) + offset) & ((1 << 64) - 1)

    def online_mask(self):
        return self.u64(self.sym('__cpu_online_mask'))

    def kernel_vars(self):
        out = {}
        for name, fmt in (('jiffies_64', '<Q'), ('panic_cpu', '<i'), ('oops_in_progress', '<i'),
                          ('tick_do_timer_cpu', '<i'), ('__cpu_online_mask', '<Q'), ('vabits_actual', '<Q')):
            if name in self.map.sym:
                try:
                    out[name] = struct.unpack(fmt, self.read_va(self.sym(name), struct.calcsize(fmt)))[0]
                except Refused:
                    pass
        return out

    def counter_offset(self):
        """Seconds between the 19.2 MHz system counter (TrustZone's and the AOP's log times) and the kernel's clock,
        from sched_clock's epoch ('cd' in kernel/time/sched_clock.c: read_data[0].epoch_ns/epoch_cyc at 8/16, rate
        at 96 in 5.10), or None."""
        if 'cd' not in self.map.sym:
            return None
        raw = self.read_va(self.sym('cd'), 104)
        epoch_ns, epoch_cyc = struct.unpack_from('<QQ', raw, 8)
        rate = struct.unpack_from('<Q', raw, 96)[0]
        if not rate or not epoch_cyc:
            return None
        return epoch_cyc / rate - epoch_ns / 1e9

    def is_text(self, addr):
        if self.sym('_text') <= addr < self.map.etext + self.kaslr:
            return True
        lo, hi = self.map.sym.get('_sinittext'), self.map.sym.get('_einittext')   # until init memory is freed
        return bool(lo and hi) and lo + self.kaslr <= addr < hi + self.kaslr

    def symbolize(self, addr):
        name = self.map.symbolize(addr - self.kaslr)
        return '%#x %s' % (addr, name) if name else '%#x' % addr


# ---------------------------------------------------------------------------------------------------- TZ diag


COUNTER_HZ = 19.2e6           # the system counter (QTimer): TrustZone's and the AOP's log times, from power-on
AOP_DATARAM = 0xe0000         # where the AOP sees its data RAM (the DATARAM.BIN region)


def tz_diag(b, dataram=None, offset=None):
    """TrustZone's diagnostic area (struct tzdbg_t, magic 'adzt', as the msm tz_log driver reads it) in a copy of
    OCIMEM -> text; with a copy of the AOP's data RAM (DATARAM), the AOP's log too. Their times are the system
    counter's; with offset (counter time - kernel time in seconds, from the kernel's sched_clock epoch: the capture
    summary's), each also in the kernel's clock. Interrupt counts are per CPU since TZ started; SWDogBa (TZ's own
    watchdog bark) is routine."""
    kt = (lambda t: '  kernel %12.6f' % (t / COUNTER_HZ - offset)) if offset is not None else (lambda t: '')
    out = ['system counter time - kernel time: %.6f s' % offset] if offset is not None else []
    h = b.find(b'adzt')
    if h < 0:
        out.append('no TZ diagnostic area (magic adzt) in this region')
        return '\n'.join(out + aop_log(dataram, kt)) + '\n'
    magic, ver, cpus, vmid, boot, rst, intoff, ring, ringlen, wake = struct.unpack_from('<10I', b, h)
    cpus = min(cpus, 8)
    out += ['tzdbg at +%#x: version %#x, %d CPUs' % (h, ver, cpus),
            'boot entries (per CPU): warm boot entry/exit, power collapse entry/exit, PSCI entry/exit, last warm jump']
    for c in range(cpus):
        if h + boot + c * 40 + 36 <= len(b):
            out.append('  cpu%d wb %d/%d pc %d/%d psci %d/%d jump %#x' % (
                (c,) + struct.unpack_from('<6IQI', b, h + boot + c * 40)[:7]))
    out.append('reset entries (per CPU: type, count):')
    for c in range(cpus):
        out.append('  cpu%d type %#x count %d' % ((c,) + struct.unpack_from('<II', b, h + rst + c * 8)))
    n = struct.unpack_from('<I', b, h + intoff - 4)[0]
    out.append('interrupts: number, name, count per CPU')
    for i in range(min(n, 256)):
        o = h + intoff + i * 56
        if o + 56 > len(b):
            break
        num = struct.unpack_from('<I', b, o + 4)[0]
        name = b[o + 8:o + 24].split(b'\0')[0].decode(errors='replace')
        counts = struct.unpack_from('<8I', b, o + 24)
        note = ''
        if any(counts):
            note = '   (routine)' if name.startswith(('SWDogBa', 'CPU Wak', 'PDC')) else '   <-- fired'
        if name:
            out.append('  %-4d %-16s %s%s' % (num, name, ' '.join('%6d' % x for x in counts), note))
    log = b[h + ring:h + ring + ringlen]
    entries = sorted((int(m.group(1), 16), m.group(2).decode(errors='replace'))   # a ring: sort by time
                     for m in re.finditer(rb'\[([0-9a-f]{16})\]\(([^)]*)\)', log))
    out.append('TZ log (%d entries; system counter time from power-on%s):' % (
        len(entries), ', then kernel time' if offset is not None else '; the kernel clock starts a few seconds later'))
    out += ['  %12.6f s%s  (%s)' % (ticks / COUNTER_HZ, kt(ticks), args) for ticks, args in entries]
    return '\n'.join(out + aop_log(dataram, kt)) + '\n'


def aop_log(a, kt):
    """The AOP's event log in a copy of its data RAM: a descriptor named 'AOP DDR Log' gives the ring's address (as
    the AOP sees it) and size; 32-byte entries, each with a counter time stamp."""
    i = a.find(b'AOP DDR Log\0') if a else -1
    while 0 <= i and i + 36 <= len(a):
        addr, size = struct.unpack_from('<II', a, i + 28)
        off = addr - AOP_DATARAM
        if 0 <= off and off + size <= len(a) and 0 < size <= 0x10000:
            ev = sorted(e[1:] for e in (struct.unpack_from('<IQ5I', a, o) for o in range(off, off + size - 31, 32))
                        if e[1])
            return ['AOP log (%d entries at data RAM +%#x; system counter time%s):' % (
                len(ev), off, ', then kernel time' if kt(0) else '')] + [
                '  %12.6f s%s  ev %#x  %d %d %d %d' % ((ts / COUNTER_HZ, kt(ts)) + tuple(rest)) for ts, *rest in ev]
        i = a.find(b'AOP DDR Log\0', i + 1)
    return ['no AOP log in the data RAM copy'] if a else []


# ---------------------------------------------------------------------------------------------------- tasks


def pahole_offsets(vmlinux):
    """{'task_struct': {'size': N, 'state': off, ...}, ...} for the structures 'kmsg' reads."""
    want = {
        'task_struct': ['state', 'stack', 'flags', 'on_cpu', 'cpu', 'prio', 'policy', 'se', 'sched_info', 'tasks',
                        'mm', 'exit_state', 'in_iowait', 'pid', 'tgid', 'thread_node', 'nvcsw', 'nivcsw',
                        'start_time', 'comm', 'signal', 'thread'],
        'sched_entity': ['exec_start', 'sum_exec_runtime'],
        'sched_info': ['pcount', 'run_delay', 'last_arrival', 'last_queued'],
        'signal_struct': ['nr_threads', 'thread_head'],
        'thread_struct': ['cpu_context'],
        'cpu_context': ['fp', 'sp', 'pc'],
        'rq': ['lock', 'nr_running', 'nr_switches', 'nr_uninterruptible', 'curr', 'idle', 'clock', 'clock_task',
               'nr_iowait', 'cpu', 'online'],
    }
    member = re.compile(r'^\t[^\t].*?(\w+)(?:\[\d+\])*(?::\d+)?(?:\s+__attribute__\(\(.*?\)\))?;'
                        r'\s*/\*\s*(\d+)(?::\s*(\d+))?\s+\d+\s*\*/')
    out = {}
    for struct_name, fields in want.items():
        text = subprocess.run(['pahole', '-C', struct_name, vmlinux], capture_output=True, text=True,
                              check=True).stdout
        if not text.strip():
            raise ValueError('pahole knows no struct %s' % struct_name)
        got = {}
        for line in text.splitlines():
            m = member.match(line)
            if m and m.group(1) in fields and m.group(1) not in got:
                got[m.group(1)] = [int(m.group(2)), int(m.group(3))] if m.group(3) else int(m.group(2))
            m = re.search(r'/\* size: (\d+)', line)
            if m and 'size' not in got and not line.startswith('\t\t'):
                got['size'] = int(m.group(1))
        missing = [f for f in fields if f not in got]
        if missing:
            raise ValueError('struct %s: no %s' % (struct_name, ', '.join(missing)))
        out[struct_name] = got
    return out


class Tasks:
    def __init__(self, k, log, deadline):
        self.k, self.log, self.deadline = k, log, deadline
        o = k.off
        self.ts, self.se, self.si = o['task_struct'], o['sched_entity'], o['sched_info']
        self.sig, self.rq = o['signal_struct'], o['rq']
        self.ctx = o['thread_struct']['cpu_context']
        self.cc = o['cpu_context']

    def task(self, va):
        ts = self.ts
        raw = self.k.read_va(va, ts['size'])
        q = lambda off: struct.unpack_from('<Q', raw, off)[0]
        i32 = lambda off: struct.unpack_from('<i', raw, off)[0]
        iow = ts['in_iowait']
        iowait = (struct.unpack_from('<I', raw, iow[0])[0] >> iow[1]) & 1 if isinstance(iow, list) else 0
        se, si, ctx = ts['se'], ts['sched_info'], ts['thread'] + self.ctx
        t = {'va': va, 'state': struct.unpack_from('<q', raw, ts['state'])[0], 'stack': q(ts['stack']),
             'flags': struct.unpack_from('<I', raw, ts['flags'])[0], 'on_cpu': i32(ts['on_cpu']),
             'cpu': struct.unpack_from('<I', raw, ts['cpu'])[0], 'prio': i32(ts['prio']),
             'policy': struct.unpack_from('<I', raw, ts['policy'])[0], 'mm': q(ts['mm']),
             'exit_state': i32(ts['exit_state']), 'iowait': iowait, 'pid': i32(ts['pid']), 'tgid': i32(ts['tgid']),
             'comm': raw[ts['comm']:ts['comm'] + 16].split(b'\0')[0].decode(errors='replace'),
             'exec_start': q(se + self.se['exec_start']), 'sum_exec': q(se + self.se['sum_exec_runtime']),
             'pcount': q(si + self.si['pcount']), 'run_delay': q(si + self.si['run_delay']),
             'last_arrival': q(si + self.si['last_arrival']), 'last_queued': q(si + self.si['last_queued']),
             'nvcsw': q(ts['nvcsw']), 'nivcsw': q(ts['nivcsw']), 'start_time': q(ts['start_time']),
             'signal': q(ts['signal']), 'thread_node': q(ts['thread_node']),
             'fp': q(ctx + self.cc['fp']), 'sp': q(ctx + self.cc['sp']), 'pc': q(ctx + self.cc['pc'])}
        t['state_char'] = state_char(t['state'], t['exit_state'])
        return t

    def walk(self, limit=30000):
        """All tasks: the thread-group leaders on init_task.tasks, and the threads of each on signal->thread_head."""
        k, ts = self.k, self.ts
        head = k.sym('init_task') + ts['tasks']
        tasks, seen, leaders = [], set(), []
        p = k.sym('init_task')
        while len(leaders) < limit:
            if p in seen:
                break
            seen.add(p)
            leaders.append(p)
            try:
                nxt = k.u64(p + ts['tasks'])
            except (Refused, struct.error) as e:
                self.log('tasks: process list broken after %d processes: %s' % (len(leaders), e))
                break
            if nxt == head:
                break
            p = nxt - ts['tasks']
            if time.time() > self.deadline:
                self.log('tasks: out of time after %d processes' % len(leaders))
                break
        done = set()
        for lead in leaders:
            if time.time() > self.deadline:
                self.log('tasks: out of time after %d tasks' % len(tasks))
                break
            try:
                t = self.task(lead)
            except (Refused, struct.error) as e:
                self.log('tasks: task %#x unreadable: %s' % (lead, e))
                continue
            group = [t]
            done.add(lead)
            if t['signal']:
                try:
                    thead = t['signal'] + self.sig['thread_head']
                    q = k.u64(thead)
                    n = 0
                    while q != thead and n < 5000:
                        tv = q - ts['thread_node']
                        if tv not in done:
                            done.add(tv)
                            th = self.task(tv)
                            group.append(th)
                            q = th['thread_node']
                        else:
                            q = k.u64(q)
                        n += 1
                except (Refused, struct.error) as e:
                    self.log('tasks: threads of %d unreadable: %s' % (t['pid'], e))
            tasks.extend(group)
        return tasks

    def runqueues(self, ncpu, online):
        k, rq = self.k, self.rq
        offs = k.percpu_offsets(ncpu)
        out = []
        for cpu in range(ncpu):
            va = k.percpu('runqueues', offs[cpu])
            try:
                raw = k.read_va(va, rq['size'])
            except Refused as e:
                out.append({'cpu': cpu, 'error': str(e)})
                continue
            q = lambda off: struct.unpack_from('<Q', raw, off)[0]
            out.append({'cpu': cpu, 'online': bool(online >> cpu & 1),
                        'lock': struct.unpack_from('<I', raw, rq['lock'])[0],
                        'nr_running': struct.unpack_from('<I', raw, rq['nr_running'])[0],
                        'nr_switches': q(rq['nr_switches']), 'nr_uninterruptible': q(rq['nr_uninterruptible']),
                        'curr': q(rq['curr']), 'idle': q(rq['idle']), 'clock': q(rq['clock']),
                        'clock_task': q(rq['clock_task']), 'nr_iowait': struct.unpack_from('<i', raw, rq['nr_iowait'])[0]})
        return out

    def stack(self, t, running):
        """Frames from the saved context (a task that is not running), or a frame-record search of the stack."""
        k = self.k
        base = t['stack']
        try:
            raw = k.read_va(base, STACK_SIZE)
        except Refused as e:
            return ['  <stack %#x unreadable: %s>' % (base, e)]
        val = lambda va: struct.unpack_from('<Q', raw, va - base)[0] if base <= va <= base + STACK_SIZE - 8 else None
        strip = lambda a: a | ~((1 << 48) - 1) & ((1 << 64) - 1) if a >> 55 & 1 else a   # pointer auth bits
        lines = []
        if not running:
            lines.append('  pc %s' % k.symbolize(t['pc']))
            fp = t['fp']
            for _ in range(64):
                if not base <= fp <= base + STACK_SIZE - 16:
                    break
                nfp, lr = val(fp), val(fp + 8)
                lr = strip(lr)
                if not k.is_text(lr):
                    break
                lines.append('  %s' % k.symbolize(lr))
                if nfp <= fp:
                    break
                fp = nfp
            return lines
        # Running: its registers are gone, its saved context is old. Frame records (fp, lr) are still on the stack.
        # The live chain runs from the frame of the function that was executing up to the top of the stack, where
        # the outermost record has fp 0 (kthreads: ret_from_fork; user tasks: the el0 entry frame). Take the lowest
        # record whose chain ends that way (stale records below the live ones can still prefix it: check the first
        # frames against the task's state), and the longest chain if that is another one.
        def chain_from(slot):
            chain, fp = [], slot
            for _ in range(96):
                nfp, lr = val(fp), val(fp + 8)
                if nfp is None or lr is None or not k.is_text(strip(lr)):
                    return chain, False
                chain.append(strip(lr))
                if nfp == 0:
                    return chain, True
                if not fp < nfp < base + STACK_SIZE:
                    return chain, False
                fp = nfp
            return chain, False
        lowest, longest = None, []
        for slot in range(base, base + STACK_SIZE - 16, 16):
            nfp, lr = val(slot), val(slot + 8)
            if not ((nfp == 0 or slot < nfp < base + STACK_SIZE) and lr is not None and k.is_text(strip(lr))):
                continue
            chain, ends = chain_from(slot)
            if ends and lowest is None and len(chain) >= 2:
                lowest = (slot, chain)
            if len(chain) > len(longest):
                longest = chain
        lines.append('  (running: frame records found on its stack; the newest frames may include stale ones)')
        if lowest:
            lines.append('  chain from %#x (lowest one that reaches the top of the stack):' % lowest[0])
            lines += ['    %s' % k.symbolize(a) for a in lowest[1]]
        if longest and (not lowest or longest != lowest[1]):
            lines.append('  longest chain:')
            lines += ['    %s' % k.symbolize(a) for a in longest]
        return lines


# ---------------------------------------------------------------------------------------------------- capture


class Capture:
    def __init__(self, mem, outdir, args, rows=None):
        self.mem, self.out, self.args, self.rows = mem, outdir, args, rows or []
        self.ram = os.path.join(outdir, 'ram')
        os.makedirs(self.ram, exist_ok=True)
        self.start = time.time()
        self.deadline = self.start + args.budget
        self.logf = open(os.path.join(self.ram, 'capture.log'), 'a')
        self.summary = []
        self.k = None
        self.counter = None        # system counter time - kernel time (s), once the printk step has read it
        self.saved = set()         # regions read so far
        self.tz = {}               # OCIMEM and DATARAM copies, for tzdiag.txt

    def log(self, msg):
        line = '%6.1fs %s' % (time.time() - self.start, msg)
        self.logf.write(line + '\n')
        self.logf.flush()
        print(line, file=sys.stderr, flush=True)

    def write(self, name, data):
        path = os.path.join(self.ram, name)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, 'wb' if isinstance(data, (bytes, bytearray)) else 'w') as f:
            f.write(data)
        return path

    def step(self, name, fn):
        if time.time() > self.deadline:
            self.log('%s: skipped (out of time)' % name)
            return None
        t0, n0 = time.time(), self.mem.bytes_read
        try:
            result = fn()
            self.log('%s: done in %.1fs (%d KB read)' % (name, time.time() - t0, (self.mem.bytes_read - n0) >> 10))
            return result
        except Exception as e:   # one failed step must not cost the others
            self.log('%s: FAILED: %s: %s' % (name, type(e).__name__, e))
            return None

    def run(self, ddr):
        a = self.args
        smap = SystemMap(a.system_map)
        image = load_kernel_file(a.kernel) if a.kernel else None
        offsets = json.load(open(a.offsets)) if a.offsets else None
        if self.rows:
            self.write('table.txt', ''.join('0x%012x %10d KB  %-22s %s\n' % (b, l >> 10, d, n) for b, l, d, n in self.rows))
        self.k = k = Kernel(self.mem, smap, self.log, offsets, image)
        if a.banner:
            k.banner_want = open(a.banner, 'rb').read().split(b'\0')[0]
        base = self.step('kernel search', lambda: k.find(ddr, a.base, min(self.deadline, time.time() + a.search_time),
                                                          a.scan_all))
        result = {'kernel': '%#x' % base if base is not None else None}
        if base is not None:
            result['kaslr'] = '%#x' % k.kaslr
            result.update(self.step('printk ring', self.printk) or {})
            self.step('printk-safe buffers', self.printk_safe)
        self.step('reset-reason and TrustZone regions', lambda: self.regions(
            ('RST_STAT', 'PMIC_PON', 'FSM_STS', 'FSM_CTRL', 'PMON_HIS', 'LOAD.CMM', 'OCIMEM', 'DATARAM')))
        self.step('TrustZone diagnostics', self.tzdiag)
        if base is not None and offsets:
            result.update(self.step('tasks', self.tasks) or {})
        elif base is not None:
            self.log('tasks: skipped (no --offsets)')
        if not a.no_regions:
            self.step('other small regions', lambda: self.regions(None))
        if base is not None and not a.no_image:
            self.step('kernel image', self.kernel_image)
        result['seconds'] = round(time.time() - self.start, 1)
        result['kb_read'] = self.mem.bytes_read >> 10
        self.write('result.json', json.dumps(result, indent=1) + '\n')
        self.write('summary.txt', '\n'.join(self.summary) + '\n')
        return result

    def printk(self):
        k = self.k
        layout, raw, descs, infos, data = k.printk_ring()
        self.write('printk/prb.bin', raw)
        self.write('printk/descs.bin', descs)
        self.write('printk/infos.bin', infos)
        self.write('printk/text.bin', data)
        try:
            counter = self.counter = k.counter_offset()
        except (Refused, struct.error):
            counter = None
        layout.update(kernel_base=k.base, kaslr=k.kaslr, kimage_voffset=k.voffset, memstart_addr=k.memstart,
                      va_bits=k.va_bits, banner=k.banner, vars=k.kernel_vars(), counter_minus_kernel_s=counter)
        self.write('printk/layout.json', json.dumps({x: ('%#x' % y if isinstance(y, int) and y > 4096 else y)
                                                     for x, y in layout.items()}, indent=1) + '\n')
        records = parse_ring(layout['count_bits'], descs, infos, data, layout['size_bits'])
        lines = dmesg_lines(records)
        with open(os.path.join(self.out, 'dmesg-ram.txt'), 'w') as f:
            f.write('\n'.join(lines) + '\n')
        with open(os.path.join(self.ram, 'records.tsv'), 'w') as f:
            f.write('seq\tts_ns\tlevel\tfacility\tflags\tcaller\tstate\tsubsystem\tdevice\tproblem\ttext\n')
            for r in records:
                text = r['text'].decode(errors='backslashreplace') if r['text'] is not None else ''
                f.write('%d\t%d\t%d\t%d\t%d\t%#x\t%s\t%s\t%s\t%s\t%s\n' % (
                    r['seq'], r['ts'], r['level'], r['facility'], r['flags'], r['caller'], r['state'],
                    r['subsystem'], r['device'], r['problem'] or '', text.replace('\\', '\\\\').replace('\t', '\\t')
                    .replace('\n', '\\n')))
        seqs = [r['seq'] for r in records if r['state'] != 'reserved']
        gaps = sum(b - a - 1 for a, b in zip(seqs, seqs[1:]) if b > a + 1)
        bad = sum(1 for r in records if r['problem'])
        reserved = [r for r in records if r['state'] == 'reserved']
        first, last = (records[0]['ts'] / 1e9, records[-1]['ts'] / 1e9) if records else (0, 0)
        v = layout['vars']
        self.summary += ['kernel at %#x (KASLR %#x): %s' % (k.base, k.kaslr, k.banner),
                         'printk ring: %d records, seq %s..%s, %.3f..%.3f s, %d missing in between, %d with problems, '
                         '%d reserved (a writer was in the middle)' % (len(records), seqs[0] if seqs else '-',
                                                                      seqs[-1] if seqs else '-', first, last, gaps, bad,
                                                                      len(reserved)),
                         'jiffies_64 %s, panic_cpu %s, oops_in_progress %s, online CPUs %s' % (
                             v.get('jiffies_64'), v.get('panic_cpu'), v.get('oops_in_progress'),
                             bin(v.get('__cpu_online_mask', 0))),
                         'system counter time - kernel time: %s s (TrustZone and AOP logs use the counter)' % (
                             '%.6f' % counter if counter is not None else '?'), '', 'last kernel messages:']
        self.summary += lines[-40:] + ['']
        return {'records': len(records), 'first_ts': round(first, 3), 'last_ts': round(last, 3), 'missing': gaps}

    def printk_safe(self):
        k = self.k
        n = self.args.nr_cpus
        offs = k.percpu_offsets(n)
        found = 0
        for cpu in range(n):
            for name in ('safe_print_seq', 'nmi_print_seq'):
                if name not in k.map.sym:
                    continue
                raw = k.read_va(k.percpu(name, offs[cpu]), 8192)
                length, lost = struct.unpack_from('<iI', raw, 0)
                if length > 0 or lost:
                    found += 1
                    text = raw[32:32 + min(max(length, 0), 8160)]
                    self.write('printk-safe/cpu%d-%s.txt' % (cpu, name), text)
                    self.summary.append('cpu%d %s: %d bytes not yet in the ring, %d lost' % (cpu, name, length, lost))
        self.log('printk-safe: %d buffers with text' % found)

    def regions(self, only):
        done = 0
        for base, length, desc, name in self.rows:
            if name.upper().startswith('DDR') or length > 8 << 20 or length == 0:
                continue
            key = name.upper().split('.')[0]
            if only is not None and key not in only and name.upper() not in only:
                continue
            if (base, name) in self.saved:
                continue
            if time.time() > self.deadline:
                self.log('regions: out of time')
                break
            safe = re.sub(r'[^A-Za-z0-9_.-]', '_', name) or '%x.bin' % base
            try:
                data = self.mem.read(base, length)
            except Refused as e:
                self.log('region %s: %s' % (name, e))
                continue
            self.write('regions/' + safe, data)
            self.saved.add((base, name))
            done += 1
            if key in ('OCIMEM', 'DATARAM'):
                self.tz[key] = data
            if length <= 16:
                self.summary.append('%s (%s) @%#x: %s' % (name, desc, base, data.hex()))
        return done

    def tzdiag(self):
        if 'OCIMEM' not in self.tz:
            self.log('TrustZone diagnostics: no OCIMEM region read')
            return
        text = tz_diag(self.tz['OCIMEM'], self.tz.get('DATARAM'), self.counter)
        self.write('tzdiag.txt', text)
        self.summary += [l for l in text.splitlines() if 'fired' in l or re.search(r'type 0x[1-9a-f]', l)] + ['']

    def tasks(self):
        k, a = self.k, self.args
        tk = Tasks(k, self.log, min(self.deadline, time.time() + a.tasks_time))
        online = k.online_mask()
        try:
            rqs = tk.runqueues(a.nr_cpus, online)
        except (Refused, struct.error) as e:
            self.log('run queues unreadable: %s' % e)
            rqs = []
        tasks = tk.walk()
        by_va = {t['va']: t for t in tasks}
        now = max([r.get('clock', 0) for r in rqs] + [0])
        with open(os.path.join(self.ram, 'tasks.tsv'), 'w') as f:
            f.write('pid\ttgid\tcomm\tstate\tcpu\ton_cpu\tprio\tpolicy\tiowait\tlast_ran_s_ago\tqueued_s_ago\t'
                    'run_delay_s\tsum_exec_s\tnvcsw\tnivcsw\tflags\n')
            for t in sorted(tasks, key=lambda t: (t['tgid'], t['pid'])):
                ago = (now - t['last_arrival']) / 1e9 if t['last_arrival'] and now >= t['last_arrival'] else -1
                qago = (now - t['last_queued']) / 1e9 if t['last_queued'] and now >= t['last_queued'] else -1
                f.write('%d\t%d\t%s\t%s\t%d\t%d\t%d\t%d\t%d\t%.3f\t%.3f\t%.3f\t%.3f\t%d\t%d\t%#x\n' % (
                    t['pid'], t['tgid'], t['comm'], t['state_char'], t['cpu'], t['on_cpu'], t['prio'], t['policy'],
                    t['iowait'], ago, qago, t['run_delay'] / 1e9, t['sum_exec'] / 1e9, t['nvcsw'], t['nivcsw'],
                    t['flags']))
        cpus = ['cpu online lock     nr_running nr_uninterruptible nr_iowait clock_s      curr']
        for r in rqs:
            if 'error' in r:
                cpus.append('%3d %s' % (r['cpu'], r['error']))
                continue
            c = by_va.get(r['curr'])
            if c is None and r['curr']:
                try:      # the idle tasks of CPUs other than 0 are not on the task list
                    c = by_va[r['curr']] = tk.task(r['curr'])
                except (Refused, struct.error):
                    pass
            cur = '%d %s%s' % (c['pid'], c['comm'], ' (idle)' if r['curr'] == r['idle'] else '') if c else '%#x' % r['curr']
            cpus.append('%3d %-6s %#-8x %10d %18d %9d %12.6f %s' % (
                r['cpu'], r['online'], r['lock'], r['nr_running'], struct.unpack('<q', struct.pack('<Q', r['nr_uninterruptible']))[0],
                r['nr_iowait'], r['clock'] / 1e9, cur))
        self.write('cpus.txt', '\n'.join(cpus) + '\n')
        # stacks: the tasks running on each CPU, every D-state task, and the watchdog's feeder
        running = {r['curr'] for r in rqs if 'curr' in r and r['curr'] != r.get('idle')}
        pick = [t for t in tasks if t['va'] in running]
        pick += [t for t in tasks if t['state_char'] == 'D' and t['va'] not in running]
        pick += [t for t in tasks if t['comm'].startswith('watchdog') and t['va'] not in running
                 and t['state_char'] != 'D']
        out = []
        for t in pick[:a.max_stacks]:
            if time.time() > self.deadline:
                out.append('(out of time)')
                break
            ago = (now - t['last_arrival']) / 1e9 if t['last_arrival'] and now >= t['last_arrival'] else -1
            out.append('%d %s state %s cpu %d on_cpu %d last ran %.3f s before the newest run-queue clock%s' % (
                t['pid'], t['comm'], t['state_char'], t['cpu'], t['on_cpu'], ago,
                ' (RUNNING on its CPU)' if t['va'] in running else ''))
            try:
                out += tk.stack(t, t['va'] in running)
            except Exception as e:
                out.append('  <unwind failed: %s>' % e)
            out.append('')
        self.write('stacks.txt', '\n'.join(out) + '\n')
        dstate = [t for t in tasks if t['state_char'] == 'D']
        wd = [t for t in tasks if t['comm'] == 'watchdog_servic']   # comm is 15 characters
        self.summary += ['tasks: %d (%d in D state); newest run-queue clock %.3f s' % (len(tasks), len(dstate), now / 1e9)]
        self.summary += cpus
        for t in wd:
            self.summary.append('watchdog_service pid %d: state %s, cpu %d, last ran %.3f s before the newest clock' % (
                t['pid'], t['state_char'], t['cpu'], (now - t['last_arrival']) / 1e9 if t['last_arrival'] else -1))
        for t in dstate[:30]:
            self.summary.append('D: %d %s (cpu %d)' % (t['pid'], t['comm'], t['cpu']))
        self.summary.append('')
        return {'tasks': len(tasks), 'd_state': len(dstate)}

    def kernel_image(self):
        k = self.k
        path = os.path.join(self.ram, 'kernel-image.bin')
        with open(path, 'wb') as f:
            for off in range(0, k.image_size, 1 << 20):
                if time.time() > self.deadline:
                    self.log('kernel image: out of time at %d MB' % (off >> 20))
                    break
                f.write(self.mem.read(k.base + off, min(1 << 20, k.image_size - off)))


# ---------------------------------------------------------------------------------------------------- main


def capture_args(p):
    p.add_argument('outdir')
    p.add_argument('--system-map', required=True, help='System.map of the running kernel')
    p.add_argument('--kernel', help='its Image / Image.gz / boot image: the header and banner must match')
    p.add_argument('--banner', help='a file with its linux_banner ("Linux version ..."): must match')
    p.add_argument('--offsets', help="JSON from 'offsets VMLINUX' (task and run-queue walk)")
    p.add_argument('--base', type=lambda s: int(s, 0), help='try this physical address for the kernel first')
    p.add_argument('--scan-all', action='store_true', help='look at every candidate address')
    p.add_argument('--budget', type=float, default=420, help='seconds for everything (default 420)')
    p.add_argument('--search-time', type=float, default=150, help='seconds for the kernel search (default 150)')
    p.add_argument('--tasks-time', type=float, default=150, help='seconds for tasks and stacks (default 150)')
    p.add_argument('--max-stacks', type=int, default=400)
    p.add_argument('--nr-cpus', type=int, default=8)
    p.add_argument('--no-image', action='store_true', help='do not copy the kernel image (32 MB)')
    p.add_argument('--no-regions', action='store_true', help='only the reset-reason regions, not the other small ones')


def main():
    if len(sys.argv) < 2 or sys.argv[1] not in ('console', 'table', 'reset', 'kmsg', 'kmsg-file', 'offsets', 'tzdiag'):
        sys.exit(__doc__)
    action = sys.argv[1]
    if action == 'tzdiag':
        p = argparse.ArgumentParser(prog='crashdump.py tzdiag')
        p.add_argument('ocimem', help='a saved OCIMEM region (in a kmsg capture: ram/regions/OCIMEM.BIN)')
        p.add_argument('--aop', help="a saved copy of the AOP's data RAM (default: DATARAM.BIN beside OCIMEM)")
        p.add_argument('--offset', type=float, help='system counter time - kernel time, in seconds (default: '
                       "counter_minus_kernel_s of the capture's ram/printk/layout.json)")
        a = p.parse_args(sys.argv[2:])
        d = os.path.dirname(os.path.abspath(a.ocimem))
        aop = a.aop or (os.path.join(d, 'DATARAM.BIN') if os.path.exists(os.path.join(d, 'DATARAM.BIN')) else None)
        offset = a.offset
        if offset is None:
            try:
                offset = json.load(open(os.path.join(d, '..', 'printk', 'layout.json'))).get('counter_minus_kernel_s')
            except (OSError, ValueError):
                pass
        sys.stdout.write(tz_diag(open(a.ocimem, 'rb').read(), open(aop, 'rb').read() if aop else None, offset))
        return
    if action == 'offsets':
        if len(sys.argv) != 3:
            sys.exit(__doc__)
        print(json.dumps(pahole_offsets(sys.argv[2]), indent=1))
        return
    if action == 'kmsg-file':
        p = argparse.ArgumentParser(prog='crashdump.py kmsg-file')
        capture_args(p)
        p.add_argument('--ram', action='append', required=True, metavar='ADDR=FILE')
        a = p.parse_args(sys.argv[2:])
        mem = RamFiles(a.ram)
        result = Capture(mem, a.outdir, a).run(mem.ddr())
        print('kmsg: %s' % json.dumps(result))
        return
    if action == 'kmsg':
        p = argparse.ArgumentParser(prog='crashdump.py kmsg')
        capture_args(p)
        a = p.parse_args(sys.argv[2:])
    phone = Sahara()
    phone.handshake()
    if action == 'table':
        for base, length, desc, name in phone.regions():
            print('0x%012x %10d KB  %-22s %s' % (base, length >> 10, desc, name))
    elif action == 'console':
        out = sys.argv[2]
        os.makedirs(out, exist_ok=True)
        try:
            area = phone.read(RAMOOPS, RAMOOPS_SIZE)
        except Refused as e:
            sys.exit(str(e))
        open(os.path.join(out, 'ramoops.bin'), 'wb').write(area)
        sig, start, used = struct.unpack_from('<4sII', area, CONSOLE_OFFSET)
        if sig != b'DBGC':
            sys.exit('no console zone at 0x%x (signature %r)' % (RAMOOPS + CONSOLE_OFFSET, sig))
        data = area[CONSOLE_OFFSET + 12:CONSOLE_OFFSET + ZONE]
        text = data[start:used] + data[:start] if used == len(data) else data[:used]
        open(os.path.join(out, 'console.txt'), 'wb').write(text.replace(b'\0', b''))
        records = sum(1 for i in range(6) if struct.unpack_from('<4sII', area, i * ZONE)[2])
        print('console: %d bytes -> %s/console.txt; %d panic records' % (len(text), out, records))
    elif action == 'kmsg':
        try:
            rows = phone.regions()
        except Exception as e:   # the table is a convenience: without it, the DDR layout every OnePlus 6 has
            print('table unreadable: %s' % e, file=sys.stderr)
            rows = []
        result = Capture(phone, a.outdir, a, rows).run(ddr_regions(rows))
        print('kmsg: %s' % json.dumps(result))
    else:
        phone.reset()


if __name__ == '__main__':
    main()
