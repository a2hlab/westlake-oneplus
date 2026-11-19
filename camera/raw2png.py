#!/usr/bin/env python3
"""raw2png.py: turn a CAMSS RAW10 capture (MIPI-packed Bayer, as written by yavta) into PNG images.

  python3 raw2png.py FRAME.raw [--pixfmt SBGGR10P] [--width W --height H] [--stride BPL]
  python3 raw2png.py FRAME.raw --info SENSOR.txt      (the .txt cam-capture.sh writes next to the frames)

Writes FRAME.png (simple demosaic at half resolution: each 2x2 Bayer cell becomes one RGB pixel, grey-world
white balance, gamma 2.2) and FRAME-raw.png (the raw mosaic as 8-bit grey, full resolution), and prints
per-channel statistics so a black, saturated or noisy frame is obvious without looking at it.
Needs numpy and Pillow. No camera calibration: colours are approximate.
"""
import argparse
import re
import sys

import numpy as np
from PIL import Image

ORDERS = {'RGGB': 'RGGB', 'BGGR': 'BGGR', 'GRBG': 'GRBG', 'GBRG': 'GBRG'}


def unpack_raw10(buf, width, height, stride):
    """MIPI RAW10: 4 pixels in 5 bytes (4 MSB bytes, then one byte with the 4x2 LSBs)."""
    need = stride * height
    if len(buf) < need:
        sys.exit(f'frame has {len(buf)} bytes, expected at least {need} ({stride} x {height})')
    a = np.frombuffer(buf[:need], dtype=np.uint8).reshape(height, stride)
    a = a[:, :width * 5 // 4].reshape(height, width // 4, 5).astype(np.uint16)
    out = np.empty((height, width // 4, 4), dtype=np.uint16)
    for i in range(4):
        out[:, :, i] = (a[:, :, i] << 2) | ((a[:, :, 4] >> (2 * i)) & 3)
    return out.reshape(height, width)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('raw')
    ap.add_argument('--info')
    ap.add_argument('--pixfmt', default='SBGGR10P')
    ap.add_argument('--width', type=int)
    ap.add_argument('--height', type=int)
    ap.add_argument('--stride', type=int)
    o = ap.parse_args()
    if o.info:
        kv = dict(re.findall(r'(\w+)=(\S+)', open(o.info).read()))
        o.pixfmt = kv.get('pixfmt', o.pixfmt)
        o.width = o.width or int(kv['width'])
        o.height = o.height or int(kv['height'])
        o.stride = o.stride or int(kv['bytesperline'])
    if not (o.width and o.height):
        sys.exit('need --width/--height or --info')
    if not o.stride:
        o.stride = (o.width * 10 // 8 + 15) // 16 * 16
    m = re.match(r'S(RGGB|BGGR|GRBG|GBRG)10P$', o.pixfmt)
    if not m:
        sys.exit(f'unsupported pixel format {o.pixfmt} (RAW10 packed Bayer only)')
    order = ORDERS[m.group(1)]

    raw = unpack_raw10(open(o.raw, 'rb').read(), o.width, o.height, o.stride)
    base = re.sub(r'\.raw$', '', o.raw)
    Image.fromarray((raw >> 2).astype(np.uint8)).save(base + '-raw.png')

    planes = {}
    for idx, (dy, dx) in enumerate(((0, 0), (0, 1), (1, 0), (1, 1))):
        planes.setdefault(order[idx], []).append(raw[dy::2, dx::2].astype(np.float32))
    r = planes['R'][0]
    g = (planes['G'][0] + planes['G'][1]) / 2
    b = planes['B'][0]
    black = 64.0  # 10-bit pedestal typical of Sony sensors
    rgb = np.stack([r, g, b], axis=-1) - black
    rgb = np.clip(rgb, 0, None)
    for name, ch in zip('RGB', range(3)):
        c = rgb[..., ch]
        print(f'{name}: mean {c.mean():7.1f}  min {c.min():6.1f}  max {c.max():6.1f}  (10-bit, black level {black:.0f} removed)')
    means = rgb.reshape(-1, 3).mean(axis=0) + 1e-6
    rgb *= means[1] / means                    # grey world
    top = np.percentile(rgb, 99.5) + 1e-6
    rgb = np.clip(rgb / top, 0, 1) ** (1 / 2.2)
    Image.fromarray((rgb * 255).astype(np.uint8)).save(base + '.png')
    print(f'wrote {base}.png ({o.width // 2}x{o.height // 2} RGB) and {base}-raw.png ({o.width}x{o.height} mosaic)')


if __name__ == '__main__':
    main()
