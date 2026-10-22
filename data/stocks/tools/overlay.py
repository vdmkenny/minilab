"""Draw a reading back onto a render of the chart, to check it by eye.

usage: overlay.py PDF_DIR READING_JSON OUT_PNG [DPI]

The grid points of every channel are drawn as small coloured crosses (R red, G green, B blue,
black-and-white magenta) at the page position the axis calibration maps them back to.
"""

import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import numpy as np
from PIL import Image, ImageDraw

import charts
from read_all import find
from read_raster import render

pdf_dir, path, out = sys.argv[1], sys.argv[2], sys.argv[3]
dpi = int(sys.argv[4]) if len(sys.argv) > 4 else 300
r = json.load(open(path))
cfg = next(c for c in charts.VECTOR + charts.RASTER if c["id"] == r["id"])
s = dpi / 72.0
rgb = render(find(pdf_dir, cfg["pdf"]), cfg["page"], dpi)
x0, y0, x1, y1 = cfg["frame"]
pad = 12
a, b, c, d = int((x0 - pad) * s), int((y0 - pad) * s), int((x1 + pad) * s), int((y1 + pad) * s)
img = Image.fromarray((rgb[b:d, a:c] * 255).astype(np.uint8))
dr = ImageDraw.Draw(img)
col = {"r": (230, 0, 0), "g": (0, 170, 0), "b": (0, 0, 255), "bw": (220, 0, 220)}
xa, xb = r["x_calibration"]["a"], r["x_calibration"]["b"]
ya, yb = r["y_calibration"]["a"], r["y_calibration"]["b"]
for ch, cv in r["curves"].items():
    for lh, dens in zip(cv["grid"]["log_h"], cv["grid"]["density"]):
        px = (lh - xa) / xb * s - a
        py = (dens - ya) / yb * s - b
        dr.line([(px - 4, py), (px + 4, py)], fill=col[ch], width=1)
        dr.line([(px, py - 4), (px, py + 4)], fill=col[ch], width=1)
for v, pos, _ in r["x_calibration"]["ticks"]:
    dr.line([(pos * s - a, img.height - 6), (pos * s - a, img.height)], fill=(255, 128, 0), width=2)
for v, pos, _ in r["y_calibration"]["ticks"]:
    dr.line([(0, pos * s - b), (6, pos * s - b)], fill=(255, 128, 0), width=2)
img.save(out)
