"""List the words and painted paths inside a region of a PDF page, to set up a chart reading.

usage: explore_vector.py PDF PAGE X0 Y0 X1 Y1   (top-left page points)
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from pdfvec import page_paths, page_words

pdf, page = sys.argv[1], int(sys.argv[2])
x0, y0, x1, y1 = (float(v) for v in sys.argv[3:7])

print("words:")
for text, a, b, c, d in page_words(pdf, page):
    if a >= x0 and c <= x1 and b >= y0 and d <= y1:
        print(f"  {text!r:24} x {a:7.2f}-{c:7.2f} (c {0.5 * (a + c):7.2f})  y {b:7.2f}-{d:7.2f} (c {0.5 * (b + d):7.2f})")

print("paths:")
for i, p in enumerate(page_paths(pdf, page)):
    for j, sp in enumerate(p["subpaths"]):
        if sp[:, 0].min() < x0 or sp[:, 0].max() > x1 or sp[:, 1].min() < y0 or sp[:, 1].max() > y1:
            continue
        w = sp[:, 0].max() - sp[:, 0].min()
        h = sp[:, 1].max() - sp[:, 1].min()
        kind = "S" if p["stroked"] else ""
        kind += "F" if p["filled"] else ""
        col = p["stroke"] if p["stroked"] else p["fill"]
        print(
            f"  {i:4d}.{j:<3d} {kind:2} n={len(sp):4d} x {sp[:, 0].min():7.2f}-{sp[:, 0].max():7.2f} "
            f"y {sp[:, 1].min():7.2f}-{sp[:, 1].max():7.2f} w={w:6.2f} h={h:6.2f} "
            f"lw={p['width']:.2f} dash={tuple(round(d, 2) for d in p['dash'])} col={tuple(round(c, 2) for c in col)}"
        )
