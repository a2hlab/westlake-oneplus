#!/usr/bin/env python3
"""test_crashdump.py: checks crashdump.py's kernel-log reader without a phone. It builds a RAM image the way a
5.10 arm64 kernel leaves it (Image header and banner at a 2 MB-aligned address, KASLR-moved virtual addresses, a
printk ring written with the kernel's reserve/wrap/reuse rules, per-CPU printk-safe buffers), together with a
matching System.map, runs `kmsg-file` on it and compares the decoded log with what was written. Two cases: the
static ring inside the kernel image, and a log_buf_len= ring in the linear map below a negative memstart_addr.
Also TrustZone's diagnostic area and the AOP's log, from OCIMEM and AOP data RAM regions written the same way.

  python3 scripts/test_crashdump.py [WORKDIR]"""
import json
import os
import random
import struct
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ID_MASK = (1 << 62) - 1
U64 = (1 << 64) - 1
TEXT = 0xffff800010000000            # VA_BITS 48: PAGE_END + 256 MB
PAGE_OFFSET = 0xffff000000000000
IMAGE_SIZE = 0x1000000
SYMS = {  # offsets from _text (all inside the image)
    '_text': 0, 'stext': 0x10000, '__schedule': 0x20000, '_etext': 0x100000, 'kimage_vaddr': 0x100000,
    'linux_banner': 0x100020, 'memstart_addr': 0x101008, 'kimage_voffset': 0x101018, 'prb': 0x102000,
    'printk_rb_static': 0x102040, '__per_cpu_offset': 0x103000, '__cpu_online_mask': 0x103100, 'jiffies_64': 0x103200,
    'panic_cpu': 0x103208, '__per_cpu_start': 0x110000, 'safe_print_seq': 0x110000, 'nmi_print_seq': 0x112000,
    '_printk_rb_static_descs': 0x200000, '_printk_rb_static_infos': 0x260000, '__log_buf': 0x400000,
    'swapper_pg_dir': 0x500000, '_end': IMAGE_SIZE,
}
BANNER = b'Linux version 5.10.194-test (builder@test) #1 SMP PREEMPT\n'


class RingWriter:
    """The writer side of kernel/printk/printk_ringbuffer.c, one CPU: ids, lpos, wrapping blocks, reuse."""

    def __init__(self, count_bits, size_bits):
        self.cb, self.sb = count_bits, size_bits
        self.count, self.size = 1 << count_bits, 1 << size_bits
        self.descs = bytearray(self.count * 24)
        self.infos = bytearray(self.count * 88)
        self.data = bytearray(self.size)
        self.head_id = self.tail_id = (-(self.count + 1)) & ID_MASK          # DESC0_ID
        self.head_lpos = self.tail_lpos = (-self.size) & U64                  # BLK0_LPOS
        struct.pack_into('<QQQ', self.descs, (self.count - 1) * 24, (3 << 62) | self.head_id, 1, 1)
        struct.pack_into('<Q', self.infos, 0, (-self.count) & U64)
        self.alive = []      # (id, text, state)

    def evict(self):
        did, begin, nxt, text, state = self.alive.pop(0)
        idx = did & (self.count - 1)
        struct.pack_into('<Q', self.descs, idx * 24, (3 << 62) | did)
        self.tail_lpos = nxt
        self.tail_id = (did + 1) & ID_MASK

    def write(self, text, ts, state=2, text_len=None, level=6, dataless=False):
        did = (self.head_id + 1) & ID_MASK
        idx = did & (self.count - 1)
        while self.alive and self.alive[0][0] == (did - self.count) & ID_MASK:
            self.evict()
        self.head_id = did
        if dataless:
            begin = nxt = 1                                                   # FAILED_LPOS
        else:
            blk = (len(text) + 8 + 7) // 8 * 8
            begin = self.head_lpos
            nxt = begin + blk
            wraps = begin >> self.sb != nxt >> self.sb
            if wraps:
                nxt = (nxt & ~(self.size - 1)) + blk
            nxt &= U64
            while (nxt - self.tail_lpos) & U64 > self.size:
                self.evict()
            self.head_lpos = nxt
            struct.pack_into('<Q', self.data, begin & (self.size - 1), did)
            at = 0 if wraps else begin & (self.size - 1)
            struct.pack_into('<Q', self.data, at, did)
            self.data[at + 8:at + 8 + len(text)] = text
        struct.pack_into('<QQQ', self.descs, idx * 24, (state << 62) | did, begin, nxt)
        old = struct.unpack_from('<Q', self.infos, idx * 88)[0]
        seq = idx if old == 0 and idx != 0 else (old + self.count) & U64
        self.infos[idx * 88:idx * 88 + 88] = bytes(88)
        struct.pack_into('<QQHBBI', self.infos, idx * 88, seq, ts, len(text) if text_len is None else text_len, 0,
                         level << 5, 0x80000000 | 3)
        self.alive.append((did, begin, nxt, text, state))
        return seq


def fill(w, n, rng, t0=0):
    msgs = []
    for i in range(n):
        body = ('msg %d ' % i + ''.join(rng.choice('abcdefghij ') for _ in range(rng.randint(10, 180)))).encode()
        if i % 97 == 5:
            body += b'\n second line of %d' % i
        msgs.append((w.write(body, t0 + i * 1000003), body))
    return msgs


def build(work, dynamic):
    rng = random.Random(7)
    base, ram_size = 0x80000000, 0x6000000
    phys = 0x81200000                                     # the kernel; a decoy Image header at 0x80200000
    kaslr = 0x1a2c00000
    memstart = -0x3f00000000 + base                       # a randomized linear map: negative
    ram = bytearray(ram_size)
    put = lambda pa, data: ram.__setitem__(slice(pa - base, pa - base + len(data)), data)
    lin = lambda pa: PAGE_OFFSET + (pa - memstart)
    va = lambda name: TEXT + SYMS[name] + kaslr
    img = lambda name: phys + SYMS[name]
    head = bytearray(64)
    struct.pack_into('<IIQQQ', head, 0, 0x14000000, 0, 0, IMAGE_SIZE, 0xa)
    head[0x38:0x3c] = b'ARM\x64'
    decoy = bytearray(head)
    struct.pack_into('<Q', decoy, 16, IMAGE_SIZE + 0x200000)
    put(0x80200000, decoy)
    put(phys, head)
    put(img('linux_banner'), BANNER + b'\0')
    put(img('kimage_vaddr'), struct.pack('<Q', TEXT + kaslr))
    put(img('kimage_voffset'), struct.pack('<Q', TEXT + kaslr - phys))
    put(img('memstart_addr'), struct.pack('<q', memstart))
    put(img('jiffies_64'), struct.pack('<Q', 0x1234567))
    put(img('panic_cpu'), struct.pack('<i', -1))
    put(img('__cpu_online_mask'), struct.pack('<Q', 0xff))
    # per-CPU areas in the linear map; cpu 3 has text in its printk-safe buffer
    areas = [0x83000000 + cpu * 0x10000 for cpu in range(8)]
    put(img('__per_cpu_offset'), struct.pack('<8Q', *[(lin(a) - va('__per_cpu_start')) & U64 for a in areas]))
    safe = b'printk from NMI context, not yet flushed\n'
    put(areas[3] + SYMS['safe_print_seq'] - SYMS['__per_cpu_start'], struct.pack('<iI', len(safe), 0) + bytes(24) + safe)
    if dynamic:
        cb, sb = 15, 20
        w = RingWriter(cb, sb)
        msgs = fill(w, 40000, rng)
        ring_pa = 0x83800000
        descs_pa, infos_pa, data_pa = ring_pa + 0x1000, ring_pa + 0x100000, ring_pa + 0x400000
        ptrs = (lin(descs_pa), lin(infos_pa), lin(data_pa))
        prb_pa = ring_pa
        prb_va = lin(ring_pa)
    else:
        cb, sb = 14, 19
        w = RingWriter(cb, sb)
        msgs = fill(w, 30000, rng)
        descs_pa, infos_pa, data_pa = img('_printk_rb_static_descs'), img('_printk_rb_static_infos'), img('__log_buf')
        ptrs = (va('_printk_rb_static_descs'), va('_printk_rb_static_infos'), va('__log_buf'))
        prb_pa, prb_va = img('printk_rb_static'), va('printk_rb_static')
    # the newest records: a data-less one, a committed one, one a writer had only reserved
    msgs.append((w.write(b'', 0, dataless=True, text_len=0), None))
    msgs.append((w.write(b'committed, not finalized', 2 ** 40), b'committed, not finalized'))
    msgs.append((w.write(b'half written', 2 ** 40 + 1, state=0, text_len=0), b'half written'))
    put(descs_pa, w.descs)
    put(infos_pa, w.infos)
    put(data_pa, w.data)
    put(prb_pa, struct.pack('<I4xQQQQI4xQQQQ', cb, ptrs[0], ptrs[1], w.head_id, w.tail_id, sb, ptrs[2],
                            w.head_lpos, w.tail_lpos, 0))
    put(img('prb'), struct.pack('<Q', prb_va))
    open(os.path.join(work, 'ram.bin'), 'wb').write(ram)
    with open(os.path.join(work, 'System.map'), 'w') as f:
        for name, off in sorted(SYMS.items(), key=lambda x: x[1]):
            f.write('%016x %s %s\n' % (TEXT + off, 'T' if off < 0x100000 else 'D', name))
    alive = {seq for seq, _ in msgs[-len(w.alive):]}
    return [(seq, body) for seq, body in msgs if seq in alive], safe, phys, kaslr


def check_tz(work):
    """TrustZone's diagnostic area and the AOP's log, as a capture reads them from the phone's OCIMEM and AOP data
    RAM regions, and as the tzdiag command decodes the saved copies (finding DATARAM and the offset by itself)."""
    import argparse
    sys.path.insert(0, HERE)
    import crashdump
    hz, offset = 19.2e6, 4.5
    oci = bytearray(0x20000)
    h, boot, rst, intoff, ring = 0x13000, 0x40, 0x180, 0x200, 0x1200
    log = b''.join(b'[%016x](%s)' % (int(t * hz), a) for t, a in ((9.0, b'b'), (7.0, b'a')))
    struct.pack_into('<10I', oci, h, 0x747a6461, 0x90001, 8, 0, boot, rst, intoff, ring, len(log), 0)
    for c in range(8):
        struct.pack_into('<6IQI', oci, h + boot + c * 40, 10 + c, 10 + c, 9, 0, 9, 0, 0, 0)
    struct.pack_into('<II', oci, h + rst + 2 * 8, 0x33, 1)
    struct.pack_into('<I', oci, h + intoff - 4, 2)
    for i, (num, name, counts) in enumerate(((186, b'NOCERR', (1, 0, 0, 0, 0, 2, 0, 0)), (33, b'NSWDogB', (0,) * 8))):
        struct.pack_into('<HBBI16s8I', oci, h + intoff + i * 56, 0, 1, 0, num, name, *counts)
    oci[h + ring:h + ring + len(log)] = log
    dram = bytearray(0x8000)
    dram[0x100:0x10c] = b'AOP DDR Log\0'
    struct.pack_into('<II', dram, 0x100 + 28, 0xe0000 + 0x4000, 3 * 32)
    for k, (t, ev) in enumerate(((12.0, 0x13e), (11.0, 0x12c), (0, 0))):
        struct.pack_into('<IQ5I', dram, 0x4000 + k * 32, 0, int(t * hz), ev, 1, 2, 3, 4)

    class Mem:
        bytes_read = 0

        def read(self, addr, size):
            return bytes({0x14680000: oci, 0xb0e0000: dram, 0xc264000: b'\x01\0\0\0'}[addr][:size])

    out = os.path.join(work, 'tz')
    rows = [(0xc264000, 4, 'reset status', 'RST_STAT.BIN'), (0x14680000, len(oci), 'OCIMEM', 'OCIMEM.BIN'),
            (0xb0e0000, len(dram), 'AOP Data RAM region', 'DATARAM.BIN')]
    cap = crashdump.Capture(Mem(), out, argparse.Namespace(budget=60), rows)
    cap.counter = offset
    first = cap.regions(('RST_STAT', 'OCIMEM', 'DATARAM'))
    cap.tzdiag()
    again = cap.regions(None)
    text = open(os.path.join(out, 'ram', 'tzdiag.txt')).read()
    os.makedirs(os.path.join(out, 'ram', 'printk'), exist_ok=True)
    json.dump({'counter_minus_kernel_s': offset}, open(os.path.join(out, 'ram', 'printk', 'layout.json'), 'w'))
    run = subprocess.run([sys.executable, os.path.join(HERE, 'crashdump.py'), 'tzdiag',
                          os.path.join(out, 'ram', 'regions', 'OCIMEM.BIN')], capture_output=True, text=True)
    want = ['system counter time - kernel time: 4.500000 s', '  cpu2 type 0x33 count 1',
            '  186  NOCERR                1      0      0      0      0      2      0      0   <-- fired',
            '  cpu3 wb 13/13 pc 9/0 psci 9/0 jump 0x0', '      7.000000 s  kernel     2.500000  (a)',
            'AOP log (2 entries at data RAM +0x4000; system counter time, then kernel time):',
            '     11.000000 s  kernel     6.500000  ev 0x12c  1 2 3 4']
    problems = ['missing: %r' % w for w in want if w not in text.splitlines()]
    if text.index('(a)') > text.index('(b)') or text.index('ev 0x12c') > text.index('ev 0x13e'):
        problems.append('logs not in time order')
    if (first, again) != (3, 0):
        problems.append('regions read %s then %s, expected 3 then 0' % (first, again))
    if run.stdout != text:
        problems.append('tzdiag on the saved regions differs from the capture: %s' % (run.stderr or run.stdout)[-500:])
    if not any('fired' in l for l in cap.summary):
        problems.append('no fired interrupt in the summary')
    if problems:
        print('FAIL TrustZone and AOP diagnostics:\n  ' + '\n  '.join(problems))
        return 1
    print('ok   TrustZone and AOP diagnostics: interrupts, resets, both logs in kernel time')
    return 0


def main():
    work = sys.argv[1] if len(sys.argv) > 1 else tempfile.mkdtemp(prefix='crashdump-test-')
    failures = check_tz(work)
    for dynamic in (False, True):
        d = os.path.join(work, 'dynamic' if dynamic else 'static')
        os.makedirs(d, exist_ok=True)
        expected, safe, phys, kaslr = build(d, dynamic)
        out = os.path.join(d, 'out')
        run = subprocess.run([sys.executable, os.path.join(HERE, 'crashdump.py'), 'kmsg-file', out, '--ram',
                              '0x80000000=' + os.path.join(d, 'ram.bin'), '--system-map', os.path.join(d, 'System.map'),
                              '--no-image', '--budget', '120'], capture_output=True, text=True)
        result = json.loads(run.stdout.split('kmsg: ', 1)[1]) if 'kmsg: ' in run.stdout else {}
        records = [l.rstrip('\n').split('\t') for l in open(os.path.join(out, 'ram', 'records.tsv'))][1:] \
            if os.path.exists(os.path.join(out, 'ram', 'records.tsv')) else []
        got = [(int(r[0]), r[6], r[10].encode().decode('unicode_escape').encode('latin-1') if r[10] else None)
               for r in records]
        problems = []
        if result.get('kernel') != '%#x' % phys or result.get('kaslr') != '%#x' % kaslr:
            problems.append('kernel %s kaslr %s, expected %#x %#x' % (result.get('kernel'), result.get('kaslr'), phys, kaslr))
        if [s for s, _, _ in got] != [s for s, _ in expected]:
            problems.append('sequence numbers differ: %d decoded, %d expected (first %s / %s)'
                            % (len(got), len(expected), got[:1], expected[:1]))
        for (seq, state, text), (eseq, body) in zip(got, expected):
            if body is None:
                continue
            if state == 'reserved' and text is not None and text.startswith(body):
                continue
            if text != body:
                problems.append('seq %d: %r != %r' % (seq, text, body))
                break
        dmesg = open(os.path.join(out, 'dmesg-ram.txt')).read() if os.path.exists(os.path.join(out, 'dmesg-ram.txt')) else ''
        if ' second line of ' not in dmesg or '<reserved> half written' not in dmesg:
            problems.append('dmesg-ram.txt lacks the multi-line or the reserved record')
        safe_file = os.path.join(out, 'ram', 'printk-safe', 'cpu3-safe_print_seq.txt')
        if not os.path.exists(safe_file) or open(safe_file, 'rb').read() != safe:
            problems.append('printk-safe buffer of cpu 3 not found')
        name = 'dynamic ring (linear map)' if dynamic else 'static ring (kernel image)'
        if problems:
            failures += 1
            print('FAIL %s:\n  %s\n%s' % (name, '\n  '.join(problems), run.stderr[-3000:]))
        else:
            print('ok   %s: %d records, kernel %s, KASLR %s' % (name, len(got), result['kernel'], result['kaslr']))
    sys.exit(1 if failures else 0)


if __name__ == '__main__':
    main()
