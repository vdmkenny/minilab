"""Find straight lines in a region of a rendered PDF page, to set up a raster chart reading.

usage: explore_raster.py PDF PAGE X0 Y0 X1 Y1 [DPI] [CROP_PNG]   (top-left page points)

Prints, in page points, the columns and rows where a large share of the region is dark
(frame edges and gridlines), and optionally saves the crop with a light 10 pt grid drawn on it.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import numpy as np
from PIL import Image, ImageDraw

from read_raster import render, _darkness

pdf, page = sys.argv[1], int(sys.argv[2])
x0, y0, x1, y1 = (float(v) for v in sys.argv[3:7])
dpi = int(sys.argv[7]) if len(sys.argv) > 7 else 300
s = dpi / 72.0
rgb = render(pdf, page, dpi)
d = _darkness(rgb)
a, b, c, e = int(x0 * s), int(y0 * s), int(x1 * s), int(y1 * s)
reg = d[b:e, a:c]
for name, prof, off in (("vertical lines (x pt)", (reg > 0.35).mean(axis=0), a), ("horizontal lines (y pt)", (reg > 0.35).mean(axis=1), b)):
    print(name)
    peaks = [i for i in range(1, len(prof) - 1) if prof[i] >= 0.25 and prof[i] >= prof[i - 1] and prof[i] >= prof[i + 1]]
    merged = []
    for p in peaks:
        if merged and p - merged[-1][-1] <= 2:
            merged[-1].append(p)
        else:
            merged.append([p])
    for grp in merged:
        p = grp[int(np.argmax([prof[q] for q in grp]))]
        print(f"  {(off + p + 0.5) / s:8.2f}  share {prof[p]:.2f}")
if len(sys.argv) > 8:
    img = Image.fromarray((rgb[b:e, a:c] * 255).astype(np.uint8))
    dr = ImageDraw.Draw(img)
    for xp in np.arange(np.ceil(x0 / 10) * 10, x1, 10):
        dr.line([((xp * s) - a, 0), ((xp * s) - a, img.height)], fill=(255, 160, 160) if xp % 50 else (255, 0, 0))
    for yp in np.arange(np.ceil(y0 / 10) * 10, y1, 10):
        dr.line([(0, (yp * s) - b), (img.width, (yp * s) - b)], fill=(160, 160, 255) if yp % 50 else (0, 0, 255))
    img.save(sys.argv[8])
