"""List the most common saturated colours inside a region of a rendered page.

usage: colours.py PDF PAGE X0 Y0 X1 Y1 [DPI]
"""
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np
from read_raster import render
pdf, page = sys.argv[1], int(sys.argv[2])
x0, y0, x1, y1 = (float(v) for v in sys.argv[3:7])
dpi = int(sys.argv[7]) if len(sys.argv) > 7 else 300
s = dpi / 72
rgb = render(pdf, page, dpi)[int(y0 * s):int(y1 * s), int(x0 * s):int(x1 * s)].reshape(-1, 3)
sat = rgb.max(axis=1) - rgb.min(axis=1)
c = (np.round(rgb[sat > 0.25] * 20) / 20)
vals, counts = np.unique(c, axis=0, return_counts=True)
for i in np.argsort(-counts)[:15]:
    print(tuple(round(float(v), 2) for v in vals[i]), counts[i])
