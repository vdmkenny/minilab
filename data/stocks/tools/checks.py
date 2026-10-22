"""Check the readings against what the datasheets state in text, and against other editions.

usage: checks.py READINGS_DIR

1. Editions: each raster cross-check chart (charts.RASTER entries with `check_against`) is
   compared with the vector reading of the same curve in another edition: largest and mean
   absolute density difference over the common log H range.
2. Speed points (colour negatives with a lux-second axis): ISO 5800 speed, S = sqrt(2) / H_M,
   H_M = sqrt(H_G * H_S), where H_G is the green exposure at 0.15 above green minimum density
   and H_S the larger of the red and blue exposures at 0.15 above their minimum densities.
   Compared with the box speed. (ISO 5800 also sets contrast conditions; this is a check of
   placement on the exposure axis, not a speed measurement.)
3. Grey-card densities stated by the maker: the density at the exposure an 18 % grey card gets
   at the box speed, H = 8.1 / S lux-seconds (reflected-light meter constant 12.5, lens factor
   0.65), compared with the stated range.
4. Ilford's stated contrast: the development times in Ilford's tables aim at G-bar 0.62. G-bar
   is computed here as the slope between the point 0.1 above base + fog and the point 1.5 log H
   further on (Ilford's definition as given in its technical leaflets).
"""

import json
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import numpy as np  # noqa: E402

import charts  # noqa: E402

out_dir = sys.argv[1]


def load(cid):
    with open(os.path.join(out_dir, cid + ".json")) as f:
        return json.load(f)


def dense(r, ch):
    c = r["curves"][ch]["dense"]
    return np.array(c["log_h"]), np.array(c["density"])


def exposure_at(x, d, target):
    """First log H at which the (rising) curve reaches `target`."""
    i = int(np.argmax(d >= target))
    if d[i] < target or i == 0:
        return None
    return x[i - 1] + (target - d[i - 1]) * (x[i] - x[i - 1]) / (d[i] - d[i - 1])


print("1. Same curve, other edition (raster check against vector reading)")
for cfg in charts.RASTER:
    if "check_against" not in cfg:
        continue
    a, b = load(cfg["id"]), load(cfg["check_against"])
    worst, tot, n = 0.0, 0.0, 0
    for ch in a["curves"]:
        xa, da = dense(a, ch)
        xb, db = dense(b, ch)
        lo, hi = max(xa[0], xb[0]), min(xa[-1], xb[-1])
        m = (xa >= lo) & (xa <= hi)
        diff = np.abs(da[m] - np.interp(xa[m], xb, db))
        worst = max(worst, float(diff.max()))
        tot += float(diff.sum())
        n += int(m.sum())
    print(f"  {cfg['id']:28} vs {cfg['check_against']:22} max {worst:.4f} D, mean {tot / n:.4f} D")

print("2. ISO 5800 speed point (colour negatives, lux-second axis)")
for cid, box in (("kodak_pro_image_100", 100), ("fujifilm_c200", 200), ("fujifilm_superia_200", 200), ("fujifilm_pro_400h", 400)):
    r = load(cid)
    h = {}
    for ch in "rgb":
        x, d = dense(r, ch)
        h[ch] = exposure_at(x, d, d[0] + 0.15)
    hs = max(h["r"], h["b"])
    hm = 0.5 * (h["g"] + hs)
    s = math.sqrt(2) / 10**hm
    print(f"  {cid:22} log H_G {h['g']:+.3f}, log H_S {hs:+.3f}: S = {s:.0f} (box {box}, {math.log2(s / box):+.2f} stop)")

print("3. Grey-card red density at the box speed")
for cid, box, lo, hi in (("kodak_pro_image_100", 100, 1.03, 1.23), ("fujifilm_superia_200", 200, 0.97, 1.16)):
    r = load(cid)
    x, d = dense(r, "r")
    lh = math.log10(8.1 / box)
    print(f"  {cid:22} log H {lh:+.2f}: red density {np.interp(lh, x, d):.3f} (stated {lo} to {hi})")

print("4. G-bar from the Ilford curves (Ilford's tables aim at 0.62)")
for cid in ("ilford_hp5_plus", "ilford_fp4_plus", "ilford_pan_f_plus", "ilford_delta_100", "ilford_delta_3200", "ilford_sfx_200", "ilford_ortho_plus"):
    r = load(cid)
    x, d = dense(r, "bw")
    x0 = exposure_at(x, d, d[0] + 0.1)
    x1 = x0 + 1.5
    if x1 > x[-1]:
        print(f"  {cid:22} curve too short for G-bar")
        continue
    g = (np.interp(x1, x, d) - (d[0] + 0.1)) / 1.5
    print(f"  {cid:22} G-bar {g:.3f}")
