"""Compare a raster chart read at two resolutions, channel by channel.

usage: compare_reads.py PDF_DIR ID [DPI_A DPI_B]
Prints, per channel, the largest and mean absolute density difference between the two reads
(over 0.01 log H steps), where the largest occurs, and the largest difference at the grid points.
"""
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np
import charts, read_raster
from read_all import finish, find

pdf_dir, cid = sys.argv[1], sys.argv[2]
cfg = next(c for c in charts.RASTER if c["id"] == cid)
da, db = (int(v) for v in sys.argv[3:5]) if len(sys.argv) > 4 else (cfg.get("dpi", 600), cfg.get("dpi2", 300))
path = find(pdf_dir, cfg["pdf"])
a = finish(cfg, read_raster.read_chart(cfg, path, da), True)
b = finish(cfg, read_raster.read_chart(cfg, path, db), True)
for ch in a["curves"]:
    xa, ya = np.array(a["curves"][ch]["dense"]["log_h"]), np.array(a["curves"][ch]["dense"]["density"])
    xb, yb = np.array(b["curves"][ch]["dense"]["log_h"]), np.array(b["curves"][ch]["dense"]["density"])
    lo, hi = max(xa[0], xb[0]), min(xa[-1], xb[-1])
    m = (xa >= lo) & (xa <= hi)
    diff = ya[m] - np.interp(xa[m], xb, yb)
    i = int(np.argmax(np.abs(diff)))
    g = np.array(a["curves"][ch]["grid"]["log_h"])
    gm = (g >= lo) & (g <= hi)
    gd = np.abs(np.array(a["curves"][ch]["grid"]["density"])[gm] - np.interp(g[gm], xb, yb))
    print(f"{ch:2} max {diff[i]:+.4f} at log H {xa[m][i]:+.3f}, mean {np.abs(diff).mean():.4f}; grid points max {gd.max():.4f}; extents {xa[0]:+.3f}..{xa[-1]:+.3f} vs {xb[0]:+.3f}..{xb[-1]:+.3f}")
